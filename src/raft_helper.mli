(** Helper function for manipualting Protobuf Generated types. 
 *)

module State : sig 


  val last_log_index_and_term : Raft_pb.state -> (int * int) 
  (** [last_log_index_and_term state] return the [(index, term)] of the last log
      entry. 
    *)

  val last_log_index: Raft_pb.state ->  int 
  (** [last_log_index state] return the index of the last log entry. 
    *)

  val is_follower : Raft_pb.state -> bool
  (** [is_follower state] returns [true] if [state] role is a follower, [false]
      otherwise. 
    *)

  val is_candidate : Raft_pb.state -> bool
  (** [is_candidate state] returns [true] if [state] role is a candidate, [false]
      otherwise. 
    *)
  
  val is_leader : Raft_pb.state -> bool
  (** [is_leader state] returns [true] if [state] role is a leader, [false]
      otherwise. 
    *)

end (* State *) 


module Follower : sig 

  val create : 
    ?current_leader:int -> 
    ?current_term:int -> 
    ?voted_for:int -> 
    ?log:Raft_pb.log_entry list ->
    configuration:Raft_pb.configuration -> 
    id:int -> 
    unit -> 
    Raft_pb.state 
  (** [create ~current_leader ~current_term ~voted_for ~log ~configuration ~id ()] creates an initial 
      follower state. 
    *)

  val become : ?current_leader:int -> term:int -> Raft_pb.state -> Raft_pb.state
  (** [become ~current_leader state term] return the new follower state. 
      
      {ul
      {li [voted_for] is [None]}
      {li [current_leader] is taken from the function argument}
      {li [current_term] is taken from the function argument}
      }
    *)
end 


module Candidate : sig

  val become : now:float ->  Raft_pb.state -> Raft_pb.state
  (** [become state now] returns the new state with Candidate role. [current_term] is 
      incremented and [vote_count] initialized to 1. (ie we assume the candidate
      votes for itself.

      The [election_timeout] is reset to a random number between the boundaries
      of the configuration. 
    *)

  val increment_vote_count : Raft_pb.candidate_state -> Raft_pb.candidate_state
  (** [increment_vote_count state] increments the candidate vote count 
      by 1.

      This function is called upon receiving a successful response to a vote request
      to one of the servers.
    *)

end (* Candidate *) 

module Leader : sig

  val become : Raft_pb.state -> float -> Raft_pb.state 
  (** [become state] returns the new state with a Leader role. 
      
       While only candidate with a majority are allowed by the protocol to 
       become a leader, this function does not perform any checks but simply 
       initialize the role of Leader. 

       The calling application is responsible to ensure that it is correct
       to become a leader. 
    *)

  val next_index_for_receiver : Raft_pb.state -> int -> int option
  (** [next_index_for_receiver state receiver_id] returns the next index 
      for the given receiver id. 

      If [state] role is not a leader or if [receiver_id] is not valid, 
      then [None] is returned. 
    *)
  
  val match_index_for_receiver : Raft_pb.state -> int -> int option
  (** [match_index_for_receiver state receiver_id] returns the match index 
      for the given receiver id. 

      If [state] role is not a leader or if [receiver_id] is not valid, 
      then [None] is returned. 
    *)

  val add_log : bytes -> Raft_pb.state -> Raft_pb.state 
  (** [add_log log_data state] adds [log_data] to the log of the [state]. 
       
      Any subsequent logical actions like creating Append Entries request is 
      left to the caller. 
    *) 

  val update_receiver_last_log_index : 
    server_id:int -> 
    log_index:int -> 
    Raft_pb.leader_state -> 
    (Raft_pb.leader_state * int) 
  (** [update_receiver_last_log_index leader_state receiver_id last_log_index] updates the leader
      state with the [last_log_index] information received from a server. (Both [next_index]
      and [match_index] are updated. 

      The function returns [(state, nb_of_replication)]. The [nb_of_replication] is 
      useful for the application to determine how many servers have replicated the log and therefore
      determine if it can be considered commited. 
    *)

  val update_receiver_deadline : 
    server_id:int -> 
    now:float -> 
    configuration:Raft_pb.configuration ->
    Raft_pb.leader_state -> 
    (Raft_pb.leader_state * float) 
  (** [update_receiver_deadline ~server_id ~now ~configuration leader_state] returns 
      the new leader state with the [server_id] heartbeat deadline updated. Additionally
      it returns the min heartbeat timeout of any of the receiver.
    *)

  val decrement_next_index : server_id:int -> Raft_pb.leader_state -> Raft_pb.leader_state 
  (** [decrement_next_index state receiver_id] decrement the next index for [receiver_id]. 
       
      This function is usally called upon an append entry failure response. 
    *)

end (* Leader  *) 

module Configuration : sig

  val is_majority : Raft_pb.configuration -> int -> bool 
  (** [is_majority configuration nb] returns true if [nb] is a majority
   *)


end (* Configuration *)

module Follow_up_action : sig

  val new_election_wait : Raft_pb.state -> Raft_pb.follow_up_action
  (** [new_election_wait state] returns a [Wait_for_rpc] follow action for 
      a new election. 
    *)
  
  val existing_election_wait : float -> float -> Raft_pb.follow_up_action 
  (** [existing_election_wait election_deadline now] returns [Wait_for_rpc] follow up 
      action for an existing election. 
    *)

  val make_heartbeat_wait : float -> Raft_pb.follow_up_action 
  (** [make_heartbeat_wait timeout] creates a [Wait_for_rpc] 
      follow up action of type type heartbeat. 
    *)

  val default : Raft_pb.state -> float -> Raft_pb.follow_up_action 

end (* Follow_up_action *)