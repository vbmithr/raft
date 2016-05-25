open Raft_pb 

module Rev_log_cache = Raft_revlogcache
module State = Raft_state

module Follower = struct 

  let create ?current_leader 
             ?current_term:(current_term = 0) 
             ?voted_for 
             ?log:(log = []) 
             ~configuration ~now ~id () = 
    let {election_timeout = t ; election_timeout_range = r; _ } = configuration in 
    let timeout = t +. (Random.float r -. (r /. 2.)) in
    {
      id; 
      current_term; 
      log;
      log_size = List.length log;
      commit_index = 0; 
      role = Follower {
        voted_for; 
        current_leader; 
        election_deadline = now +.  timeout 
      };  
      configuration; 
      global_cache = None; 
    }

  let become ?current_leader ~term ~now state = 
    let {configuration = {election_timeout = t; election_timeout_range = r; _}; _} = state in 
    let election_deadline  = now +. t +. (Random.float r -. (r /. 2.)) in

    let role = match state.role with
      | Follower follower_state -> Follower {follower_state with
        current_leader; 
        election_deadline;
      }
      | Candidate _ when state.current_term = term -> 
        Follower {
          voted_for = Some state.id;
          current_leader; 
          election_deadline; 
        }
      | _ -> Follower {
        voted_for = None;
        current_leader; 
        election_deadline;
      }
    in 
    { state with current_term = term; role } 

end 

module Candidate = struct 

  let become ~now state = 
    let {election_timeout = t; election_timeout_range = r; _ } = state.configuration in 
    let timeout = t +. (Random.float r -. (r /. 2.)) in
    let candidate_state = {
      vote_count = 1; 
      election_deadline = now +. timeout;
    } in 
    {state with 
     role = Candidate candidate_state; 
     current_term = state.current_term + 1; 
    } 

  let increment_vote_count ({vote_count; _ } as candidate_state) = 
    {candidate_state with vote_count = vote_count + 1}

end 

module Leader = struct 

  let become state now = 

    let last_log_index = State.last_log_index state in
    
    let {nb_of_server; hearbeat_timeout} = state.configuration in 
  
    let rec aux indices = function
      | (-1) -> indices
      |  i   -> 
        if i = state.id
        then 
          aux indices (i -1)
        else 
          let next_index = last_log_index + 1 in 
          let match_index = 0 in 
          let local_cache = Rev_log_cache.make ~since:last_log_index state.log in
            (* The cache is expected to be empty... which is fine since it will
             * get filled at when a new log entry will be
             * added. 
             *)

          let index:server_index = {
            server_id = i; 
            next_index; 
            match_index; 
            local_cache; 
            outstanding_request = false;
            heartbeat_deadline = now +. hearbeat_timeout;
              (* 
               * Here the expectation is that after becoming a leader
               * the client application will send a message to all the receivers
               * and therefore the heartbeat_deadline is set 
               * to [now + timeout] rather than [now].
               *
               *)
          } in 
          aux (index::indices) (i - 1)
    in 
    let indices = aux [] (nb_of_server - 1) in 
    
    {state with role = Leader {indices}}


  (*
   * Reusable function to update the index of a particular
   * receiver id. 
   *)  
  let update_index ~receiver_id ~f leader_state = 

    let indices = List.map (fun index -> 
      if index.server_id = receiver_id
      then (f index)
      else index
    ) leader_state.indices in

    {indices}

  let update_receiver_last_log_index ~receiver_id ~log_index leader_state = 

    let leader_state = update_index ~receiver_id ~f:(fun index ->
      {index with next_index = log_index + 1; match_index = log_index}
    ) leader_state
    in  

    (* Calculate the number of server which also have replicated that 
       log entry
     *)
    let nb_of_replications = List.fold_left (fun n {match_index; _ } -> 
      if match_index >= log_index 
      then n + 1 
      else n
    ) 0 leader_state.indices in 
    
    (leader_state, nb_of_replications) 

  let decrement_next_index ~log_failure ~receiver_id state leader_state = 
    let {receiver_last_log_index ; receiver_last_log_term } = log_failure in 

    let latest_log_index, latest_log_term = match state.log with
      | [] -> (0, 0) 
      | {index; term; data = _} :: _ -> (index, term)
    in

    assert(receiver_last_log_index < latest_log_index);  
      (* 
       * This is an invariant. When receiving the [Append_entries]
       * request, in case of [Log_failure] the server is responsible
       * to find the earlier log entry to synchronize with the [Leader]. 
       * 
       *)

    (* 
     * Next step is to make sur that both the [receiver_last_log_index]
     * and [receiver_last_log_term] are matching an log entry in the [Leader] 
     * log.   
     *
     * If the match is found it means that the log entry sent 
     * by the receiver is the good common log entry to synchronize the [Leader]
     * and its [Follower]. 
     *
     * In the case there is no match then we jump back to a previous term to 
     * find a entry to synchronize upon.
     *)
    let receiver_last_log_index = 
      let rec aux = function 
        | [] -> 0 
        | {index; term; _}::tl -> 
          if index > receiver_last_log_index
          then aux tl 
          else 
            if term = receiver_last_log_term
            then 
              (* Receiver last log entry is a match with a [Leader] log 
               * entry.
               *) 
              receiver_last_log_index
            else 
              (* Same index but different term, in this case, 
               * let's just go back to the last index of the previous term
               *)
              let rec aux = function 
                | [] -> 0 
                | {index; term; _}::tl when term <> receiver_last_log_term -> index
                | _::tl -> aux tl 
              in 
              aux tl 
      in
      aux state.log
    in

    update_index ~receiver_id ~f:(fun index -> 
      {index with 
       next_index = receiver_last_log_index + 1; 
       match_index = receiver_last_log_index}
    )  leader_state

  let record_response_received ~receiver_id leader_state = 
    
    update_index 
      ~receiver_id
      ~f:(fun index ->
        {index with outstanding_request = false;}
      ) 
      leader_state
    
  let min_heartbeat_timout ~now {indices} = 

    let min_heartbeat_deadline = List.fold_left (fun min_deadline {heartbeat_deadline; _ } -> 
        if heartbeat_deadline < min_deadline
        then heartbeat_deadline
        else min_deadline
      ) max_float indices
    in 
    min_heartbeat_deadline -. now 

end (* Leader *) 