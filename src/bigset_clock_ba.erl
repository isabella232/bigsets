%%% @author Russell Brown <russelldb@basho.com>
%%% @copyright (C) 2015, Russell Brown
%%% @doc
%%%
%%% @end
%%% Created :  8 Jan 2015 by Russell Brown <russelldb@basho.com>

-module(bigset_clock_ba).

-export([
         add_dot/2,
         add_dots/2,
         all_nodes/1,
         tombstone_from_digest/2,
         subtract_dots/2,
         descends/2,
         dominates/2,
         equal/2,
         fresh/0,
         fresh/1,
         from_bin/1,
         get_dot/2,
         increment/2,
         intersection/2,
         is_compact/1,
         merge/1,
         merge/2,
         seen/2,
         subtract_seen/2,
         to_bin/1
        ]).

-compile(export_all).

-export_type([clock/0, dot/0]).

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type actor() :: riak_dt_vclock:actor().
-type clock() :: {riak_dt_vclock:vclock(), dot_cloud()}.
-type dot() :: riak_dt:dot().
-type dot_cloud() :: [{riak_dt_vclock:actor(), dot_set()}].
-type dot_set() :: bigset_bitarray:bit_array().

-define(DICT, orddict).

-spec to_bin(clock()) -> binary().
to_bin(Clock) ->
    term_to_binary(Clock, [compressed]).

-spec from_bin(clock()) -> binary().
from_bin(Bin) ->
    binary_to_term(Bin).

-spec fresh() -> clock().
fresh() ->
    {riak_dt_vclock:fresh(), ?DICT:new()}.

-spec fresh({actor(), pos_integer()}) -> clock().
fresh({Actor, Cnt}) ->
    {riak_dt_vclock:fresh(Actor, Cnt), ?DICT:new()}.

%% @doc increment the entry in `Clock' for `Actor'. Return the new
%% Clock, and the `Dot' of the event of this increment. Works because
%% for any actor in the clock, the assumed invariant is that all dots
%% for that actor are contiguous and contained in this clock (assumed
%% therefore that `Actor' stores this clock durably after increment,
%% see riak_kv#679 for some real world issues, and mitigations that
%% can be added to this code.)
-spec increment(actor(), clock()) ->
                       {dot(), clock()}.
increment(Actor, {Clock, Seen}) ->
    Clock2 = riak_dt_vclock:increment(Actor, Clock),
    Cnt = riak_dt_vclock:get_counter(Actor, Clock2),
    {{Actor, Cnt}, {Clock2, Seen}}.

%% @doc get the current top event for the given actor. NOTE: Assumes
%% this is the local / event generating actor and that the dot is
%% therefore contiguous with the base.
-spec get_dot(actor(), clock()) -> dot().
get_dot(Actor, {Clock, _Dots}) ->
    {Actor, riak_dt_vclock:get_counter(Actor, Clock)}.

%% @doc a sorted list of all the actors in `Clock'.
-spec all_nodes(clock()) -> [actor()].
all_nodes({Clock, Dots}) ->
    %% NOTE the riak_dt_vclock:all_nodes/1 returns a sorted list
    lists:usort(lists:merge(riak_dt_vclock:all_nodes(Clock),
                 ?DICT:fetch_keys(Dots))).

%% @doc merge the pair of clocks into a single one that descends them
%% both.
-spec merge(clock(), clock()) -> clock().
merge({VV1, Seen1}, {VV2, Seen2}) ->
    VV = riak_dt_vclock:merge([VV1, VV2]),
    Seen = ?DICT:merge(fun(_Key, S1, S2) ->
                               bigset_bitarray:merge(S1, S2)
                       end,
                       Seen1,
                       Seen2),
    compress_seen(VV, Seen).

%% @doc merge a list of clocks `Clocks' into a single clock that
%% descends them all.
-spec merge(list(clock())) -> clock().
merge(Clocks) ->
    lists:foldl(fun merge/2,
                fresh(),
                Clocks).

%% @doc make a bigset clock from a version vector
-spec from_vv(riak_dt_vclock:vclock()) -> clock().
from_vv(Clock) ->
    {Clock, ?DICT:new()}.

%% @doc given a `Dot :: riak_dt:dot()' and a `Clock::clock()', add the
%% dot to the clock. If the dot is contiguous with events summerised
%% by the clocks VV it will be added to the VV, if it is an exception
%% (see DVV, or CVE papers) it will be added to the set of gapped
%% dots. If adding this dot closes some gaps, the dot cloud is
%% compressed onto the clock.
-spec add_dot(dot(), clock()) -> clock().
add_dot(Dot, {Clock, Seen}) ->
    Seen2 = add_dot_to_cloud(Dot, Seen),
    compress_seen(Clock, Seen2).

%% @private
-spec add_dot_to_cloud(dot(), dot_cloud()) -> dot_cloud().
add_dot_to_cloud({Actor, Cnt}, Cloud) ->
    ?DICT:update(Actor,
                 fun(Dots) ->
                         bigset_bitarray:set(Cnt, Dots)
                 end,
                 bigset_bitarray:set(Cnt, bigset_bitarray:new(1000)),
                 Cloud).

%% @doc given a list of `dot()' and a `Clock::clock()',
%% add the dots from `Dots' to the clock. All dots contiguous with
%% events summerised by the clocks VV it will be added to the VV, any
%% exceptions (see DVV, or CVE papers) will be added to the set of
%% gapped dots. If adding a dot closes some gaps, the seen set is
%% compressed onto the clock.
-spec add_dots([dot()], clock()) -> clock().
add_dots(Dots, {Clock, Seen}) ->
    Seen2 = lists:foldl(fun add_dot_to_cloud/2,
                        Seen,
                        Dots),
    compress_seen(Clock, Seen2).

%% @doc has `Dot' been seen by `Clock'. True if so, otherwise false.
-spec seen(dot(), clock()) -> boolean().
seen({Actor, Cnt}=Dot, {Clock, Seen}) ->
    (riak_dt_vclock:descends(Clock, [Dot]) orelse
     bigset_bitarray:member(Cnt, fetch_dot_set(Actor, Seen))).

%% @private
-spec fetch_dot_set(actor(), dot_cloud()) -> dot_set().
fetch_dot_set(Actor, Seen) ->
    case ?DICT:find(Actor, Seen) of
        error ->
            bigset_bitarray:new(1000);
        {ok, L} ->
            L
    end.

%% @doc Remove dots seen by `Clock' from `Dots'. Return a list of
%% `dot()' unseen by `Clock'. Return `[]' if all dots seens.
-spec subtract_seen(clock(), [dot()]) -> dot().
subtract_seen(Clock, Dots) ->
    %% @TODO(rdb|optimise) this is maybe a tad inefficient.
    lists:filter(fun(Dot) ->
                         not seen(Dot, Clock)
                 end,
                 Dots).

%% Remove `Dots' from `Clock'. Any `dot()' in `Dots' that has been
%% seen by `Clock' is removed from `Clock', making the `Clock' un-see
%% the event.
-spec subtract_dots(clock(), list(dot())) -> clock().
subtract_dots(Clock, Dots) ->
    lists:foldl(fun(Dot, Acc) ->
                        subtract_dot(Acc, Dot) end,
                Clock,
                Dots).

%% Remove an event `dot()' `Dot' from the clock() `Clock', effectively
%% un-see `Dot'.
-spec subtract_dot(clock(), dot()) -> clock().
subtract_dot(Clock, Dot) ->
    {VV, DotCloud} = Clock,
    {Actor, Cnt} = Dot,
    DotSet = fetch_dot_set(Actor, DotCloud),
    case bigset_bitarray:member(Cnt, DotSet) of
        %% Dot in the dot cloud, remove it
        true ->
            {VV, delete_dot(Dot, DotSet, DotCloud)};
        false ->
            %% Check the clock
            case riak_dt_vclock:get_counter(Actor, VV) of
                N when N >= Cnt ->
                    %% Dot in the contiguous counter Remove it by
                    %% adding > cnt to the Dot Cloud, and leaving
                    %% less than cnt in the base
                    NewBase = Cnt-1,
                    NewDots = lists:seq(Cnt+1, N),
                    NewVV = riak_dt_vclock:set_counter(Actor, NewBase, VV),
                    NewDC = case NewDots of
                                [] ->
                                    DotCloud;
                                _ ->
                                    orddict:store(Actor, bigset_bitarray:set_all(NewDots, DotSet), DotCloud)
                            end,
                    {NewVV, NewDC};
                _ ->
                    %% NoOp
                    Clock
            end
    end.

%% @private unset a dot from the dot set
-spec delete_dot(dot(), dot_set(), dot_cloud()) -> dot_cloud().
delete_dot({Actor, Cnt}, DotSet, DotCloud) ->
    DL2 = bigset_bitarray:unset(Cnt, DotSet),
    case bigset_bitarray:size(DL2) of
        0 ->
            orddict:erase(Actor, DotCloud);
        _ ->
            orddict:store(Actor, DL2, DotCloud)
    end.

%% @doc get the counter for `Actor' where `counter' is the maximum
%% _contiguous_ event sent by this clock (i.e. not including
%% exceptions.)
-spec get_contiguous_counter(riak_dt_vclock:actor(), clock()) ->
                                    pos_integer() | no_return().
get_contiguous_counter(Actor, {Clock, _Dots}=C) ->
    case riak_dt_vclock:get_counter(Actor, Clock) of
        0 ->
            error({badarg, actor_not_in_clock}, [Actor, C]);
        Cnt ->
            Cnt
    end.

-spec contiguous_seen(clock(), dot()) -> boolean().
contiguous_seen({VV, _Seen}, Dot) ->
    riak_dt_vclock:descends(VV, [Dot]).

%% @private when events have been added to a clock, gaps may have
%% closed. Check the dot_cloud entries and if gaps have closed shrink
%% the dot_cloud.
-spec compress_seen(clock(), dot_cloud()) -> clock().
compress_seen(Clock, Seen) ->
    ?DICT:fold(fun(Node, Cnts, {ClockAcc, SeenAcc}) ->
                       Cnt = riak_dt_vclock:get_counter(Node, Clock),
                       case compress(Cnt, Cnts) of
                           {Cnt, Cnts} ->
                               %% No change
                               {ClockAcc, ?DICT:store(Node, Cnts, SeenAcc)};
                           {Cnt2, Cnts2} ->
                               Compressed = bigset_bitarray:resize(Cnts2),
                               {riak_dt_vclock:merge([[{Node, Cnt2}], ClockAcc]),
                                ?DICT:store(Node, Compressed, SeenAcc)}
                       end
               end,
               {Clock, ?DICT:new()},
               Seen).

%% @private worker for `compress_seen' above. Essentially pops the
%% lowest element off the dot set and checks if it is contiguous with
%% the base. Repeatedly.
-spec compress(pos_integer(), dot_set()) -> {pos_integer(), dot_set()}.
compress(Base, BitArray) ->
    Candidate = Base+1,
    case bigset_bitarray:member(Candidate, BitArray) of
        true ->
            compress(Candidate, bigset_bitarray:unset(Candidate, BitArray));
        false ->
            {Base, BitArray}
    end.

%% @doc true if A descends B, false otherwise
-spec descends(clock(), clock()) -> boolean().
descends({ClockA, DCa}, {ClockB, DCb}) ->
    riak_dt_vclock:descends(ClockA, ClockB)
        andalso
        dotcloud_descends(DCa, DCb).

%% @private used by descends/2. returns true if `DCa' descends `DCb',
%% false otherwise. NOTE: this depends on ?DICT==orddict
-spec dotcloud_descends(dot_cloud(), dot_cloud()) -> boolean().
dotcloud_descends(DCa, DCb) ->
    NodesA = ?DICT:fetch_keys(DCa),
    NodesB = ?DICT:fetch_keys(DCb),
    case lists:umerge(NodesA, NodesB) of
        NodesA ->
            %% do the work as the set of nodes in B is a subset of
            %% those in A, meaning it is at least possible A descends
            %% B
            dotsets_descend(DCa, DCb);
        _ ->
            %% Nodes of B not a subset of nodes of A, can't possibly
            %% be descended by A.
            false
    end.

%% @private only called after `dotcloud_descends/2' when we know that
%% the the set of nodes in DCb are a subset of those in DCa
%% (i.e. every node in B is in A, so we only need compare those node's
%% dot_sets.) If all `DCb''s node's dotsets are descended by there
%% counter parts in `DCa' returns true, otherwise false.
-spec dotsets_descend(dot_cloud(), dot_cloud()) -> boolean().
dotsets_descend(DCa, DCb) ->
    %% Only called when the nodes in DCb are a subset of those in DCa,
    %% so we only need fold over that
    (catch ?DICT:fold(fun(Node, DotsetB, true) ->
                              DotsetA = ?DICT:fetch(Node, DCa),
                              dotset_descends(DotsetA, DotsetB);
                         (_Node, _, false) ->
                              throw(false)
                      end,
                      true,
                      DCb)).

%% @private returns true if `DotsetA :: dot_set()' descends `DotsetB
%% :: dot_set()' or put another way, is B a subset of A.
-spec dotset_descends(dot_set(), dot_set()) ->
                             boolean().
dotset_descends(DotsetA, DotsetB) ->
    bigset_bitarray:is_subset(DotsetB, DotsetA).

%% @doc are A and B the same logical clock? True if so.
equal(A, B) ->
    descends(A, B) andalso descends(B, A).

%% @doc true if the events in A are a strict superset of the events in
%% B, false otherwise.
dominates(A, B) ->
    descends(A, B) andalso not descends(B, A).

%% @doc intersection returns all the dots in A that are also in B. A
%% is `dot_cloud()' as returned by `complement/2'
-spec intersection(dot_cloud(), clock()) -> clock().
intersection(_DotCloud, _Clock) ->
    ok.

%% @doc subtract. Return only the events in A that are not in B. NOTE:
%% this is for comparing a set digest with a set clock, so the digest
%% (B) is _always_ a subset of the clock (A).
-spec tombstone_from_digest(Digest::clock(), SetClock::clock()) -> dot_cloud().
tombstone_from_digest(A, B) ->
    %% @TODO: implement me
    {A, B}.

%% @doc Is this clock compact, i.e. no gaps/no dot-cloud entries
-spec is_compact(clock()) -> boolean().
is_compact({_Base, DC}) ->
    is_compact_dc(DC).

is_compact_dc([]) ->
    true;
is_compact_dc([{_A, DC} | Rest]) ->
    case bigset_bitarray:is_empty(DC) of
        true ->
            is_compact_dc(Rest);
        false ->
            false
    end.