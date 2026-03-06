----------------------------------------------------------------------
-- Speculative MSI Protocol - Optimized Version
-- Includes speculative access optimization to reduce hop counts
----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
const
  ProcCount: 2;
  ValueCount: 1;
  VC0: 0;                -- requests
  VC1: 1;                -- forwarded control / invalidations
  VC2: 2;                -- data / acknowledgements
  VC3: 3;                -- speculative requests/responses
  NumVCs: VC3 - VC0 + 1;
  NetMax: 7;

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------
type
  Proc: scalarset(ProcCount);
  Value: scalarset(ValueCount);
  Home: enum { HomeType };
  Node: union { Home, Proc };

  VCType: VC0..NumVCs-1;

  MessageType: enum {
    -- Requests
    GetS,
    GetM,
    PutM,
    PutS,
    
    -- Speculative requests
    GetS_Spec,
    GetM_Spec,
    SpecOwnerToS,

    -- Forwarded / control
    Fwd_GetS,
    Fwd_GetM,
    Inv,

    -- Responses
    Data,
    InvAck,
    PutAck,
    FwdAck,
    
    -- Speculative responses
    Spec_Fail
  };

  Message:
    Record
      mtype: MessageType;
      src: Node;
      vc: VCType;
      val: Value;
      cnt: 0..ProcCount;
      fwd_to: Node;
    End;

  HomeState:
    Record
      state: enum {
        H_I, H_S, H_M,
        H_MS,   -- waiting for FwdAck after Fwd_GetS
        H_MM    -- waiting for FwdAck after Fwd_GetM
      };
      owner: Node;
      sharers: multiset [ProcCount] of Node;
      val: Value;
      pending_node: Node;
    End;

  ProcState:
    Record
      state: enum {
        P_I, P_S, P_M,
        PI_S,
        PI_M,
        PS_M,
        PM_I,
        PM_IS,
        PM_IM,
        PS_I,
        -- Speculative states
        PI_S_Spec,
        PI_M_Spec,
        PS_M_Spec
      };
      val: Value;
      acks_needed: 0..NetMax;
      acks_received: 0..NetMax;
      speculated_owner: Node;
    End;

----------------------------------------------------------------------
-- Variables
----------------------------------------------------------------------
var
  HomeNode: HomeState;
  Procs: array [Proc] of ProcState;
  Net: array [Node] of multiset [NetMax] of Message;
  msg_processed: boolean;
  LastWrite: Value;

----------------------------------------------------------------------
-- Procedures
----------------------------------------------------------------------
Procedure Send(mtype:MessageType;
               dst:Node;
               src:Node;
               vc:VCType;
               val:Value;
               cnt:0..ProcCount;
               fwd_to:Node;
               );
var msg:Message;
Begin
  Assert (MultiSetCount(i:Net[dst], true) < NetMax) "Too many messages";
  msg.mtype := mtype;
  msg.src := src;
  msg.vc := vc;
  msg.val := val;
  msg.cnt := cnt;
  msg.fwd_to := fwd_to;
  MultiSetAdd(msg, Net[dst]);
End;

Procedure ErrorUnhandledMsg(msg:Message; n:Node);
Begin
  switch msg.mtype
  case GetS, GetM, PutM, PutS, Fwd_GetS, Fwd_GetM, Inv, GetS_Spec, GetM_Spec:
    msg_processed := false;
  else
    error "Unhandled message type!";
  endswitch;
End;

Procedure ErrorUnhandledState();
Begin
  error "Unhandled state!";
End;

Procedure AddToSharersList(n:Node);
Begin
  if MultiSetCount(i:HomeNode.sharers, HomeNode.sharers[i] = n) = 0
  then
    MultiSetAdd(n, HomeNode.sharers);
  endif;
End;

Function IsSharer(n:Node) : Boolean;
Begin
  return MultiSetCount(i:HomeNode.sharers, HomeNode.sharers[i] = n) > 0
End;

Procedure RemoveFromSharersList(n:Node);
Begin
  MultiSetRemovePred(i:HomeNode.sharers, HomeNode.sharers[i] = n);
End;

Function SharerCount() : 0..ProcCount;
Begin
  return MultiSetCount(i:HomeNode.sharers, true);
End;

Procedure SendInvToSharers(rqst:Node);
Begin
  for n:Node do
    if (IsMember(n, Proc) &
        MultiSetCount(i:HomeNode.sharers, HomeNode.sharers[i] = n) != 0)
    then
      if n != rqst
      then
        Send(Inv, n, rqst, VC1, UNDEFINED, 0, UNDEFINED);
      endif;
    endif;
  endfor;
End;

----------------------------------------------------------------------
-- Home Controller
----------------------------------------------------------------------
Procedure HomeReceive(msg:Message);
var cnt:0..ProcCount;
var num_sharers:0..ProcCount;
Begin
  msg_processed := true;
  num_sharers := SharerCount();

  switch HomeNode.state
  case H_I:
    switch msg.mtype
    case GetS:
      Send(Data, msg.src, HomeType, VC2, HomeNode.val, 0, UNDEFINED);
      AddToSharersList(msg.src);
      HomeNode.state := H_S;

    case GetM:
      Send(Data, msg.src, HomeType, VC2, HomeNode.val, 0, UNDEFINED);
      HomeNode.owner := msg.src;
      HomeNode.state := H_M;

    case PutM:
      Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);

    case PutS:
      Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);

    case SpecOwnerToS:
      -- stale speculative metadata update

    else
      ErrorUnhandledMsg(msg, HomeType);
    endswitch;

  case H_S:
    if (msg.mtype = GetM)
    then
      if IsSharer(msg.src)
      then
        cnt := num_sharers - 1;
      else
        cnt := num_sharers;
      endif;

      Send(Data, msg.src, HomeType, VC2, HomeNode.val, cnt, UNDEFINED);
      SendInvToSharers(msg.src);

      MultiSetRemovePred(i:HomeNode.sharers, true);
      HomeNode.owner := msg.src;
      HomeNode.state := H_M;

    else
      switch msg.mtype
      case GetS:
        Send(Data, msg.src, HomeType, VC2, HomeNode.val, 0, UNDEFINED);
        AddToSharersList(msg.src);

      case PutM:
        RemoveFromSharersList(msg.src);
        Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);

      case PutS:
        RemoveFromSharersList(msg.src);
        if SharerCount() = 0
        then
          HomeNode.state := H_I;
        endif;
        Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);

      case SpecOwnerToS:
        -- stale speculative metadata update

      else
        ErrorUnhandledMsg(msg, HomeType);
      endswitch;
    endif;

  case H_M:
    switch msg.mtype
    case SpecOwnerToS:
      if msg.src = HomeNode.owner
      then
        HomeNode.val := msg.val;
        AddToSharersList(msg.src);
        AddToSharersList(msg.fwd_to);
        undefine HomeNode.owner;
        HomeNode.state := H_S;
      endif;

    case GetS:
      Assert (!IsUndefined(HomeNode.owner)) "H_M with undefined owner";
      Send(Fwd_GetS, HomeNode.owner, HomeType, VC1, UNDEFINED, 0, msg.src);
      HomeNode.pending_node := msg.src;
      AddToSharersList(msg.src);
      AddToSharersList(HomeNode.owner);
      HomeNode.state := H_MS;

    case GetM:
      Assert (!IsUndefined(HomeNode.owner)) "H_M with undefined owner";
      Send(Fwd_GetM, HomeNode.owner, HomeType, VC1, UNDEFINED, 0, msg.src);
      HomeNode.pending_node := msg.src;
      HomeNode.state := H_MM;

    case PutM:
      if (msg.src = HomeNode.owner)
      then
        HomeNode.val := msg.val;
        Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);
        undefine HomeNode.owner;
        HomeNode.state := H_I;
      else
        Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);
      endif;

    case PutS:
      Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);

    else
      ErrorUnhandledMsg(msg, HomeType);
    endswitch;

  case H_MS:
    switch msg.mtype
    case FwdAck:
      HomeNode.val := msg.val;
      undefine HomeNode.owner;
      HomeNode.state := H_S;

    case PutM:
      if msg.src != HomeNode.owner
      then
        Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);
      else
        msg_processed := false;
      endif;

    case PutS:
      Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);

    case GetS, GetM:
      msg_processed := false;

    case SpecOwnerToS:
      -- stale speculative metadata update while waiting for forward ack

    else
      ErrorUnhandledMsg(msg, HomeType);
    endswitch;

  case H_MM:
    switch msg.mtype
    case FwdAck:
      HomeNode.owner := HomeNode.pending_node;
      HomeNode.state := H_M;

    case PutM:
      if msg.src != HomeNode.owner
      then
        Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);
      else
        msg_processed := false;
      endif;

    case PutS:
      Send(PutAck, msg.src, HomeType, VC2, UNDEFINED, 0, UNDEFINED);

    case GetS, GetM:
      msg_processed := false;

    case SpecOwnerToS:
      -- stale speculative metadata update while waiting for forward ack

    else
      ErrorUnhandledMsg(msg, HomeType);
    endswitch;

  else
    ErrorUnhandledState();

  endswitch;
End;

----------------------------------------------------------------------
-- Cache Controller
----------------------------------------------------------------------
Procedure ProcReceive(msg:Message; p:Proc);
Begin
  msg_processed := true;

  alias ps:Procs[p].state do
  alias pv:Procs[p].val do
  alias pack:Procs[p].acks_needed do
  alias prack:Procs[p].acks_received do
  alias spec_owner:Procs[p].speculated_owner do

  switch ps
  case P_I:
    switch msg.mtype
    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);
      spec_owner := msg.src;

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case Data, InvAck, PutAck, FwdAck, Spec_Fail:
      -- stale response while already invalid
    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case P_S:
    switch msg.mtype
    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);
      undefine pv;
      ps := P_I;
      spec_owner := msg.src;

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case Data, InvAck, PutAck, FwdAck, Spec_Fail:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case P_M:
    switch msg.mtype
    case Fwd_GetS:
      Send(Data, msg.fwd_to, p, VC2, pv, 0, UNDEFINED);
      Send(FwdAck, HomeType, p, VC2, pv, 0, UNDEFINED);
      ps := P_S;

    case Fwd_GetM:
      Send(Data, msg.fwd_to, p, VC2, pv, 0, UNDEFINED);
      Send(FwdAck, HomeType, p, VC2, UNDEFINED, 0, UNDEFINED);
      undefine pv;
      ps := P_I;

    case GetS_Spec:
      Send(Data, msg.src, p, VC3, pv, 0, UNDEFINED);
      Send(SpecOwnerToS, HomeType, p, VC1, pv, 0, msg.src);
      ps := P_S;

    case GetM_Spec:
      Send(Data, msg.src, p, VC3, pv, 0, UNDEFINED);
      undefine pv;
      ps := P_I;

    case Data, InvAck, PutAck:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PI_S:
    switch msg.mtype
    case Data:
      pv := msg.val;
      ps := P_S;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);
      spec_owner := msg.src;

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case InvAck, PutAck, FwdAck, Spec_Fail:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PI_M:
    switch msg.mtype
    case Data:
      pv := msg.val;
      if msg.src = HomeType
      then
        pack := msg.cnt;
        if prack >= pack
        then
          ps := P_M;
        endif;
      else
        ps := P_M;
      endif;

    case InvAck:
      prack := prack + 1;
      if (!IsUndefined(pv) & prack >= pack)
      then
        ps := P_M;
      endif;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case Fwd_GetS, Fwd_GetM:
      msg_processed := false;

    case PutAck, FwdAck, Spec_Fail:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PS_M:
    switch msg.mtype
    case Data:
      pv := msg.val;
      pack := msg.cnt;
      if prack >= pack
      then
        ps := P_M;
      endif;

    case InvAck:
      prack := prack + 1;
      if (pack != 0 & prack >= pack)
      then
        ps := P_M;
      endif;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);
      if IsUndefined(pv)
      then
        ps := PI_M;
        pack := 0;
        prack := 0;
      endif;

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case Fwd_GetS, Fwd_GetM:
      msg_processed := false;

    case PutAck, FwdAck, Spec_Fail:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PM_I:
    switch msg.mtype
    case PutAck:
      ps := P_I;
      undefine pv;

    case Fwd_GetS:
      Send(Data, msg.fwd_to, p, VC2, pv, 0, UNDEFINED);
      Send(FwdAck, HomeType, p, VC2, pv, 0, UNDEFINED);
      ps := PM_IS;

    case Fwd_GetM:
      Send(Data, msg.fwd_to, p, VC2, pv, 0, UNDEFINED);
      Send(FwdAck, HomeType, p, VC2, UNDEFINED, 0, UNDEFINED);
      ps := PM_IM;

    case GetS_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);

    case Data, InvAck:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PM_IS:
    switch msg.mtype
    case PutAck:
      ps := P_I;
      undefine pv;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case Data, InvAck, FwdAck:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PM_IM:
    switch msg.mtype
    case PutAck:
      ps := P_I;
      undefine pv;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case Data, InvAck, FwdAck:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PS_I:
    switch msg.mtype
    case PutAck:
      ps := P_I;
      undefine pv;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case Data, InvAck, FwdAck, Spec_Fail:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  -- Speculative states
  case PI_S_Spec:
    switch msg.mtype
    case Data:
      pv := msg.val;
      ps := P_S;

    case Spec_Fail:
      -- Speculative failed, send normal request
      Send(GetS, HomeType, p, VC0, UNDEFINED, 0, UNDEFINED);
      ps := PI_S;
      undefine spec_owner;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);
      spec_owner := msg.src;

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case InvAck, PutAck, FwdAck:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PI_M_Spec:
    switch msg.mtype
    case Data:
      pv := msg.val;
      ps := P_M;

    case Spec_Fail:
      -- Speculative failed, send normal request
      Send(GetM, HomeType, p, VC0, UNDEFINED, 0, UNDEFINED);
      ps := PI_M;
      pack := 0;
      prack := 0;
      undefine spec_owner;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case InvAck, PutAck, FwdAck:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  case PS_M_Spec:
    switch msg.mtype
    case Data:
      pv := msg.val;
      pack := 0;
      ps := P_M;

    case Spec_Fail:
      -- Speculative failed, send normal request
      Send(GetM, HomeType, p, VC0, UNDEFINED, 0, UNDEFINED);
      ps := PS_M;
      pack := 0;
      prack := 0;
      undefine spec_owner;

    case Inv:
      Send(InvAck, msg.src, p, VC2, UNDEFINED, 0, UNDEFINED);
      if IsUndefined(pv)
      then
        ps := PI_M_Spec;
        undefine spec_owner;
      endif;

    case GetS_Spec, GetM_Spec:
      Send(Spec_Fail, msg.src, p, VC3, UNDEFINED, 0, UNDEFINED);

    case InvAck, PutAck, FwdAck:
      -- stale response

    else
      ErrorUnhandledMsg(msg, p);
    endswitch;

  else
    ErrorUnhandledState();
  endswitch;

  endalias;
  endalias;
  endalias;
  endalias;
  endalias;
End;

----------------------------------------------------------------------
-- Rules
----------------------------------------------------------------------
ruleset n:Proc do
  alias p:Procs[n] do

  rule "load (I->S)"
    p.state = P_I
  ==>
    Send(GetS, HomeType, n, VC0, UNDEFINED, 0, UNDEFINED);
    p.state := PI_S;
  endrule;

  rule "load speculative (I->S via cached owner)"
    p.state = P_I & !IsUndefined(p.speculated_owner)
  ==>
    Send(GetS_Spec, p.speculated_owner, n, VC3, UNDEFINED, 0, UNDEFINED);
    p.state := PI_S_Spec;
  endrule;

  rule "store (I->M)"
    p.state = P_I
  ==>
    Send(GetM, HomeType, n, VC0, UNDEFINED, 0, UNDEFINED);
    p.state := PI_M;
    p.acks_needed := 0;
    p.acks_received := 0;
  endrule;

  rule "store (S->M)"
    p.state = P_S
  ==>
    Send(GetM, HomeType, n, VC0, UNDEFINED, 0, UNDEFINED);
    p.state := PS_M;
    p.acks_needed := 0;
    p.acks_received := 0;
  endrule;

  ruleset v:Value do
    rule "store hit (M)"
      p.state = P_M
    ==>
      p.val := v;
      LastWrite := v;
    endrule;
  endruleset;

  rule "evict (M->I)"
    p.state = P_M
  ==>
    Send(PutM, HomeType, n, VC0, p.val, 0, UNDEFINED);
    p.state := PM_I;
  endrule;

  rule "evict (S->I)"
    p.state = P_S
  ==>
    Send(PutS, HomeType, n, VC0, UNDEFINED, 0, UNDEFINED);
    undefine p.val;
    p.state := PS_I;
  endrule;

  endalias;
endruleset;

ruleset n:Node do
  choose midx:Net[n] do
    alias chan:Net[n] do
    alias msg:chan[midx] do

    rule "receive"
      (msg.vc = VC3) |
      (msg.vc = VC2) |
      (msg.vc = VC1 & MultiSetCount(m:chan, chan[m].vc = VC2) = 0
                     & MultiSetCount(m:chan, chan[m].vc = VC3) = 0) |
      (msg.vc = VC0 & MultiSetCount(m:chan, chan[m].vc = VC1) = 0
                     & MultiSetCount(m:chan, chan[m].vc = VC2) = 0
                     & MultiSetCount(m:chan, chan[m].vc = VC3) = 0)
    ==>

      if IsMember(n, Home)
      then
        HomeReceive(msg);
        if msg_processed
        then
          MultiSetRemove(midx, chan);
        endif;
      else
        ProcReceive(msg, n);
        if msg_processed
        then
          MultiSetRemove(midx, chan);
        endif;
      endif;

    endrule;

    endalias;
    endalias;
  endchoose;
endruleset;

----------------------------------------------------------------------
-- Startstate
----------------------------------------------------------------------
startstate
  For v:Value do
    HomeNode.state := H_I;
    undefine HomeNode.owner;
    HomeNode.val := v;
    undefine HomeNode.pending_node;
  endfor;
  LastWrite := HomeNode.val;

  MultiSetRemovePred(i:HomeNode.sharers, true);

  for i:Proc do
    Procs[i].state := P_I;
    undefine Procs[i].val;
    Procs[i].acks_needed := 0;
    Procs[i].acks_received := 0;
    undefine Procs[i].speculated_owner;
  endfor;

  undefine Net;
endstartstate;

----------------------------------------------------------------------
-- Invariants
----------------------------------------------------------------------
invariant "values in M state match last write"
  Forall n : Proc Do
    Procs[n].state = P_M
    ->
    Procs[n].val = LastWrite
  end;

invariant "value is undefined while invalid"
  Forall n : Proc Do
    (Procs[n].state = P_I | Procs[n].state = PI_S_Spec | Procs[n].state = PI_M_Spec)
    ->
    IsUndefined(Procs[n].val)
  end;

invariant "modified implies no sharers"
  HomeNode.state = H_M
  ->
  MultiSetCount(i:HomeNode.sharers, true) = 0;

invariant "invalid implies empty owner"
  HomeNode.state = H_I
  ->
  IsUndefined(HomeNode.owner);

invariant "value in memory matches last write when invalid"
  HomeNode.state = H_I
  ->
  HomeNode.val = LastWrite;

invariant "shared implies no owner"
  HomeNode.state = H_S
  ->
  IsUndefined(HomeNode.owner);

invariant "at most one modified copy"
  Forall n1 : Proc Do
  Forall n2 : Proc Do
    (Procs[n1].state = P_M & Procs[n2].state = P_M)
    ->
    n1 = n2
  end
  end;
