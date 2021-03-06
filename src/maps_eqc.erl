-module(maps_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-compile(export_all).

-type list_map() :: list({term(), term()}).

-record(state,
    { contents = [] :: list_map(), %% The current contents of the map() represented as a list
      persist = [] :: list({reference(), list_map()}) %% Remembered older versions
    }).
    
initial_state() -> #state{}.

%% GENERATORS

%% The bastards of the atoms. The names here are not randomly chosen :)
atom() -> elements([flower, hill, pyke, rivers, sand, snow, stone, storm, waters]).

%% Generate sized map terms
map_term() ->
    ?SIZED(Sz, map_term(Sz)).
    
evil_real() ->
   frequency([
     {20, real()},
     {1, return(0.0)},
     {1, return(0.0/-1)}]).

%% Either generate a simple scalar map term, or generate a composite map term.
map_term(0) ->
    frequency([
       {100, oneof([int(), largeint(), atom(), binary(), bitstring(), bool(), char(), evil_real()])},
       {10, oneof([function0(int()), function2(int())])},
       {10, eqc_gen:largebinary()}
    ]);
map_term(K) ->
    frequency([
        {40, map_term(0)},
        {1, ?LAZY(list(map_term(K div 8)))},
        {1, ?LAZY(?LET(L, list(map_term(K div 8)), list_to_tuple(L)))},
        {1, ?LAZY(eqc_gen:map(map_term(K div 8), map_term(K div 8)))}
    ]).

%% Keys and values are map terms
map_key() -> map_term().
map_value() -> map_term().

%% Maps are generated with a resized list generator. This is not coincidental
%% because the R18 code converts from small → large maps around these points
%% (The debug build around 3 and the real-world build around 32).
%% Note we resize the generator back for the keys and values so they are normally
%% sized.
gen_map() ->
  ?SIZED(Sz, resize(Sz * 15, list({resize(Sz, map_key()), resize(Sz, map_value())}))).
  	
%% Default way to generate a list which can subsequently be used to populate
%% a map.
map_list() ->
    gen_map().

map_map() ->
    ?LET(ML, map_list(), maps:from_list(ML)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% META-COMMAND SECTION
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% Meta-commands are commands which are not present in the 'maps' module, yet
%% they encode properties which should be true of random maps().

%% REMEMBER/RECALL/BECOME
%% --------------------------------------------------------------
%% Maps are persistent. Let the model Remember a map in a given state. Later
%% recalling an older version of the map should be consistent at any point in time.
%% Also, allow us to become an older version of the map some times.
remember(Ref) ->
    maps_runner:remember(Ref).
    
remember_args(_S) -> [make_ref()].

remember_next(#state { contents = Cs, persist = Ps } = State, _, [Ref]) ->
    State#state { persist = lists:keystore(Ref, 1, Ps, {Ref, Cs}) }.
    
remember_return(_S, [_Ref]) ->
    ok.
    
%% We hardly need a feature for this

recall(Ref) ->
    maps_runner:recall(Ref).
    
%% Can only recall when there are persisted maps to recall
recall_pre(#state { persist = Ps }) -> Ps /= [].

recall_args(#state { persist = Ps }) ->
    ?LET(Pair, elements(Ps),
       [element(1, Pair)]).
       
recall_pre(#state { persist = Ps}, [Ref]) ->
    lists:keyfind(Ref,1,Ps) /= false.

recall_return(#state { persist = Ps }, [Ref]) ->
    {Ref, Cs} = lists:keyfind(Ref, 1, Ps),
    {ok, maps:from_list(Cs)}.

recall_features(_S, _, _) ->
    ["R038: Recalled a persisted version of the map successfully"].

become(Ref) ->
    maps_runner:become(Ref).
    
become_pre(#state { persist = Ps }) -> Ps /= [].

become_args(#state { persist = Ps }) ->
    ?LET(Pair, elements(Ps),
        [element(1, Pair)]).
        
become_next(#state { persist = Ps } = State, _, [Ref]) ->
    {value, {Ref, Old}, Ps2} = lists:keytake(Ref, 1, Ps),
    State#state { persist = Ps2, contents = Old }.
    
become_return(_S, [_Ref]) ->
    ok.
    
become_features(_S, [_Ref], _) ->
    ["R039: Refocus and \"become\" an old version of the map"].

%% EXTRACT
%% --------------------------------------------------------------
%% Reads the map from the runner process and ensures a copy of the map is
%% consistent.
extract() ->
    maps_runner:extract().
    
extract_args(_S) -> [].

extract_return(#state { contents = Cs }, []) ->
    maps:from_list(Cs).
    
extract_features(_S, _, _) ->
    ["R036: Maps are consistent when sending them to another process"].

%% ROUNDTRIP
%% --------------------------------------------------------------
%% Sending a map back and forth should be reflexive.
roundtrip() ->
    M = maps_runner:extract(),
    maps_runner:eq(M).
    
roundtrip_args(_S) -> [].

roundtrip_return(_S, []) ->
    true.
    
roundtrip_features(_S, _, _) ->
    ["R037: Maps sent roundtrip through another process are reflexive"].

%% POPULATE
%% --------------------------------------------------------------
%%
%% Empty maps can be "kickstarted" by quickly populating them. The meta-command
%% allows us to handle a lot of size-corner cases quickly. This checks
%% maps:from_list/1 as well as another variant where the map is filled by running
%% maps:put/3 in succession over the map.
%%
populate(Variant, Elems) ->
    maps_runner:populate(Variant, Elems).

populate_pre(#state { contents = C }) -> C == [].

populate_args(_S) ->
  [oneof([from_list, puts]),
   map_list()].
    
populate_next(State, _, [_Variant, Elems]) ->
    Contents = lists:foldl(fun({K, V}, M) -> add_contents(K, V, M) end, [], Elems),
    State#state { contents = Contents }.

populate_return(_State, [_Variant, Elems]) ->
    Contents = lists:foldl(fun({K, V}, M) -> add_contents(K, V, M) end, [], Elems),
    maps:from_list(Contents).

populate_features(_S, [Variant, _M], _) ->
    case Variant of
        from_list -> ["R017: populating an empty map with from_list/1"];
        puts -> ["R018: populating an empty map with put/2"]
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% COMMAND SECTION
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% The following section contains the standard 'maps' module commands, which
%% you can call as a user of the module.
%%

%% WITH/2
%% --------------------------------------------------------------

with(Ks) ->
    maps_runner:with(Ks).
    
with_args(#state { contents = Cs}) ->
    case Cs of
        [] -> [list(map_key())];
        Cs ->
          ?LET({P, N}, {list(elements(Cs)), list(map_key())},
             [P ++ N])
    end.
    
with_next(#state { contents = Cs } = State, _, [Ks]) ->
    State#state { contents = [{K, V} || {K, V} <- Cs, lists:member(K, Ks)] }.

with_return(#state { contents = Cs }, [Ks]) ->
    maps:from_list([{K, V} || {K, V} <- Cs, lists:member(K, Ks)]).

with_features(S, [Ks], _) ->
    ["R032: with/2 on present keys" || present(Ks, S)] ++
    ["R033: with/2 on non-existing keys" || non_existing(Ks, S)].

%% WITH/2 (Query)
%% --------------------------------------------------------------

with_q(Ks) ->
    maps_runner:with_q(Ks).
    
with_q_args(#state { contents = Cs}) ->
    case Cs of
        [] -> [list(map_key())];
        Cs ->
          ?LET({P, N}, {list(elements(Cs)), list(map_key())},
             [P ++ N])
    end.
    
with_q_return(#state { contents = Cs }, [Ks]) ->
    maps:from_list([{K, V} || {K, V} <- Cs, lists:member(K, Ks)]).
    
with_q_features(S, [Ks], _) ->
    ["R028: with/2 query on present keys" || present(Ks, S)] ++
    ["R029: with/2 query on non-existing keys" || non_existing(Ks, S)].

%% WITHOUT/2
%% --------------------------------------------------------------

without(Ks) ->
    maps_runner:without(Ks).
    
without_args(#state { contents = Cs}) ->
    case Cs of
        [] -> [list(map_key())];
        Cs ->
          ?LET({P, N}, {list(elements(Cs)), list(map_key())},
             [P ++ N])
    end.
    
without_next(#state { contents = Cs } = State, _, [Ks]) ->
    State#state { contents = [{K, V} || {K, V} <- Cs, not lists:member(K, Ks)] }.

without_return(#state { contents = Cs }, [Ks]) ->
    maps:from_list([{K, V} || {K, V} <- Cs, not lists:member(K, Ks)]).

without_features(S, [Ks], _) ->
    ["R034: withtout/2 on present keys" || present(Ks, S)] ++
    ["R035: withtout/2 on non-existing keys" || non_existing(Ks, S)].
    
%% WITHOUT/2 (Query)
%% --------------------------------------------------------------

without_q(Ks) ->
    maps_runner:without_q(Ks).
    
without_q_args(#state { contents = Cs}) ->
    case Cs of
        [] -> [list(map_key())];
        Cs ->
          ?LET({P, N}, {list(elements(Cs)), list(map_key())},
             [P ++ N])
    end.
    
without_q_return(#state { contents = Cs }, [Ks]) ->
    maps:from_list([{K, V} || {K, V} <- Cs, not lists:member(K, Ks)]).

without_q_features(S, [Ks], _) ->
    ["R030: withtout/2 query on present keys" || present(Ks, S)] ++
    ["R031: withtout/2 query on non-existing keys" || non_existing(Ks, S)].
    
%% FOLD/3
%% --------------------------------------------------------------

fold() ->
    Res = maps_runner:fold(fun(K, V, L) -> [{K, V} | L] end, []),
    sort(Res).
    
fold_args(_S) -> [].

fold_return(#state { contents = Cs }, _) ->
    sort(Cs).
    
fold_features(_S, _, _) ->
    ["R027: traverse over the map by fold/3"].

%% MAP/2
%% --------------------------------------------------------------

map(F) ->
     M = maps:map(F, maps_runner:extract()),
     ok = maps_runner:reset(M),
     M.
     
map_args(_S) ->
  ?LET(F, function2(map_value()), [F]).
     
map_next(#state { contents = Cs } = State, _, [F]) ->
    NCs = lists:map(fun({K, V}) -> {K, F(K,V)} end, Cs),
    State#state { contents = NCs }.
    
map_return(#state { contents = Cs }, [F]) ->
    NCs = lists:map(fun({K, V}) -> {K, F(K,V)} end, Cs),
    maps:from_list(NCs).
    
map_features(_S, _, _) -> ["R026: using the map/2 functor on the map()"].

%% MERGE/2
%% --------------------------------------------------------------

merge(M) ->
    maps_runner:merge(M).
    
merge_args(_S) ->
    ?LET(Elems, list({map_key(), map_value()}),
        [maps:from_list(Elems)]).
        
merge_next(#state { contents = C } = State, _, [M]) ->
    NC = maps:fold(fun (K, V, Cs) -> store(K, 1, Cs, {K, V}) end, C, M),
    State#state { contents = NC }.

merge_return(#state { contents = C }, [M]) ->
    Res = maps:fold(fun (K, V, Cs) -> store(K, 1, Cs, {K, V}) end, C, M),
    maps:from_list(Res).

merge_features(_S, _, _) ->
    ["R019: Merging two maps"].

%% FIND/2
%% --------------------------------------------------------------

find(K) ->
    maps_runner:find(K).

find_args(#state { contents = C } = S) ->
    frequency(
       [{5, [random_key(S)]} || C /= []] ++
       [{1, ?SUCHTHAT([K], [map_key()], find(K,1,C) == false)} ]).


find_return(#state { contents = C }, [K]) ->
    case find(K, 1, C) of
         false -> error;
         {K, V} -> {ok, V}
    end.

find_features(_S, _, error) -> ["R020: find on a non-existing key"];
find_features(_S, _, {ok, _V}) -> ["R021: find on an existing key"].

%% GET/3
%% --------------------------------------------------------------

m_get_default(K, Default) ->
    maps_runner:m_get(K, Default).

m_get_default_args(#state { contents = C }) ->
    frequency(
      [{5, ?LET({Pair, Default}, {elements(C), make_ref()}, [element(1, Pair), Default])} || C /= [] ] ++
      [{1, ?SUCHTHAT([K, _Default], [map_key(), make_ref()], find(K, 1, C) == false)}]).

m_get_default_return(#state { contents = C }, [K, Default]) ->
    case find(K,1,C) of
       false -> Default;
       {K, V} -> V
    end.

m_get_default_features(S, [K, _Default], _) ->
    case member(K, S) of
         true -> ["R024: get/3 on an existing key"];
         false -> ["R025: get/3 on a non-existing key"]
    end.

%% GET/2
%% --------------------------------------------------------------

m_get(K) ->
    maps_runner:m_get(K).

m_get_args(#state { contents = C }) ->
    frequency(
      [{5, ?LET(Pair, elements(C), [element(1, Pair)])} || C /= []] ++
      [{1, ?SUCHTHAT([K], [map_key()], find(K,1,C) == false)}]).

m_get_return(#state { contents = C }, [K]) ->
    case find(K,1,C) of
       false -> {error, bad_key};
       {K, V} -> V
    end.

m_get_features(_S, _, {error, bad_key}) -> ["R022: get/2 on a non-existing key"];
m_get_features(_S, _, _) -> ["R023: get on a successful key"].

%% VALUES
%% --------------------------------------------------------------

values() ->
    sort(maps_runner:values()).
    
values_args(_S) -> [].

values_return(#state { contents = C }, []) ->
    sort([V || {_, V} <- C]).

values_features(_S, _, _) ->
    ["R014: values/1 called on map"].

%% UPDATE
%% --------------------------------------------------------------

update(K, V) ->
    case maps_runner:update(K, V) of
        {error, Reason} -> {error, Reason};
        M -> M
    end.
    
update_args(#state { contents = C }) ->
    frequency(
      [{5, ?LET(Pair, elements(C), [element(1, Pair), map_value()])} || C /= [] ] ++
      [{1,  ?SUCHTHAT([K, _V], [map_key(), map_value()], find(K, 1, C) == false)}]).
        
update_next(#state { contents = C } = State, _, [K, V]) ->
    State#state { contents = replace_contents(K, V, C) }.

update_return(#state { contents = C} = S, [K, V]) ->
    case member(K, S) of
        true -> maps:from_list(replace_contents(K, V, C));
        false -> {error, badarg}
    end.

update_features(S, [K, _], _) ->
   case member(K, S) of
        true -> ["R015: update/3 on an existing key"];
        false -> ["R016: update/3 on a non-existing key"]
   end.

%% TO_LIST
%% --------------------------------------------------------------

to_list() ->
    L  = maps_runner:to_list(),
    sort(L).
    
to_list_args(_S) -> [].

to_list_return(#state { contents = C }, []) ->
    sort(C).

to_list_features(_, _, _) ->
    ["R013: to_list/1 called on map"].
    
%% REMOVE
%% --------------------------------------------------------------

remove(K) ->
    maps_runner:remove(K).
    
remove_args(#state { contents = C }) ->
    frequency(
      [{5, ?LET(Pair, elements(C), [element(1, Pair)])} || C /= [] ] ++
      [{1,  ?SUCHTHAT([K], [map_key()], find(K, 1, C) == false)}]).
        
remove_next(#state { contents = C } = State, _, [K]) ->
    State#state { contents = del_contents(K, C) }.

remove_return(#state { contents = C }, [K]) ->
    maps:from_list(del_contents(K, C)).

remove_features(S, [K], _) ->
    case member(K, S) of
       true -> ["R011: remove/2 of present key"];
       false -> ["R012: remove/2 of non-present key"]
    end.

%% KEYS
%% --------------------------------------------------------------

keys() ->
    sort(maps_runner:keys()).
    
keys_args(_S) -> [].

keys_return(#state { contents = C }, []) ->
    sort([K || {K, _} <- C]).

keys_features(_S, _, _) -> ["R010: Calling keys/1 on the map"].

%% IS_KEY
%% --------------------------------------------------------------

is_key(K) ->
    maps_runner:is_key(K).
    
is_key_args(#state { contents = C }) ->
    frequency(
        [{10, ?LET(Pair, elements(C), [element(1, Pair)])} || C /= [] ] ++
        [{1, ?SUCHTHAT([K], [map_key()], find(K, 1, C) == false)}]).

is_key_return(S, [K]) ->
    member(K, S).

is_key_features(_S, [_K], true) -> ["R001: is_key/2 on a present key"];
is_key_features(_S, [_K], false) -> ["R002: is_key/2 on a non-existing key"].

%% PUT
%% --------------------------------------------------------------

put(Key, Value) ->
    maps_runner:put(Key, Value).
    
put_args(_S) ->
    [map_key(), map_value()].

put_next(#state { contents = C } = State, _, [K, V]) ->
    State#state { contents = add_contents(K, V, C) }.

put_return(#state { contents = C}, [K, V]) ->
    maps:from_list(add_contents(K, V, C)).

put_features(S, [K, _Value], _Res) ->
    case member(K, S) of
        true -> ["R003: put/3 on existing key"];
        false -> ["R004: put on a new key"]
    end.

%% SIZE
%% --------------------------------------------------------------
size() ->
    maps_runner:size().
    
size_args(_S) -> [].

size_return(#state { contents = C }, []) ->
    length(C).
    
size_features(_S, [], Sz) ->
   if
     Sz >= 128 -> ["R005: size/1 on a 128+ map"];
     Sz >= 64 -> ["R006: size/1 on a 64+ map"];
     Sz >= 16 -> ["R007: size/1 on a 16+ map"];
     Sz == 0 -> ["R008: size/1 on an empty (0) map"];
     true -> ["R009: size/1 on a small non-empty map"]
   end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% PROPERTY AND TUNING SECTION
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% The section here contains the main property as well as the major parts of the
%% test case such as command weighting and common postcondition checks
%%

%% WEIGHT
%% -------------------------------------------------------------
%% Weighting makes sure that certain operations occur less often because they
%% are susceptible to "hiding" real problems by destroying the part of the map
%% with the problem. We do call them from time to time however.

%% Currently disabled commands
weight(_S, map) -> 0;
%% Population can only happen from the empty map, so it is very likely to fire
weight(_S, populate) -> 200;
%% Make map-altering operations with great impact unlikely 
weight(_S, with) -> 1;
weight(_S, without) -> 1;
%% Consistency checks probably find stuff even if called a bit rarer
weight(_S, extract) -> 5;
weight(_S, roundtrip) -> 5;
weight(_S, with_q) -> 5;
weight(_S, without_q) -> 5;
%% Becoming an old map should happen but be pretty unlikely
weight(_S, become) -> 1;
%% Commands that manipulate the map are slightly more interesting:
weight(_S, put) -> 20;
weight(_S, update) -> 20;
weight(_S, remove) -> 20;
weight(_S, merge) -> 20;
%% Default weight is 10 so we can make commands *less* likely than the default
weight(_S, _) -> 10.

%% PROPERTY
%% -------------------------------------------------------------

%% Common postcondition for all commands. We always report failures as
%% "Res /= Expected".
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).

%% Main property:
prop_map() ->
    ?SETUP(fun() ->
        {ok, Pid} = maps_runner:start_link(),
        fun() -> exit(Pid, kill) end
    end,
      ?FORALL(Cmds, more_commands(2, commands(?MODULE)),
        begin
          maps_runner:reset(),
          {H,S,R} = run_commands(?MODULE, Cmds),
          collect(eqc_lib:stem_and_leaf('Final map size'), model_size(S),
          collect(eqc_lib:stem_and_leaf('Command Length'), length(Cmds),
          aggregate(with_title('Commands'), command_names(Cmds),
          aggregate(with_title('Features'), call_features(H),
              pretty_commands(?MODULE, Cmds, {H,S,R}, R == ok)))))
        end)).

model_size(#state { contents = Cs }) -> length(Cs).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% HELPER ROUTINES
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% 
%% Various helper routines used by the model in more than one place.
%%
%% These implements list-operations on which =:= is used over == to make sure
%% that 0 and 0.0 compares as different elements. This lets us use lists as an
%% isomorphic representation of maps in the model.
add_contents(K, V, C) ->
    store(K, 1, C, {K, V}).

del_contents(K, C) ->
    delete(K, 1, C).

replace_contents(K, V, C) ->
    replace(K, 1, C, {K, V}).

member(K, #state { contents = C }) ->
    member(K, 1, C).

random_key(#state { contents = C }) ->
    ?LET(Pair, elements(C),
        element(1, Pair)).

present(Ks, S) ->
    lists:any(fun(K) -> member(K, S) end, Ks).
    
non_existing(Ks, S) ->
    lists:any(fun(K) -> not member(K, S) end, Ks).

store(_T, _Pos, [], New) -> [New];
store(T, Pos, [Tup|Next], New) ->
    case element(Pos, Tup) =:= T of
        true -> [New | Next];
        false -> [Tup | store(T, Pos, Next, New)]
    end.

find(_T, _Pos, []) -> false;
find(T, Pos, [Tup|Next]) ->
    case element(Pos, Tup) =:= T of
        true -> Tup;
        false -> find(T, Pos, Next)
    end.
    
member(_T, _Pos, []) -> false;
member(T, Pos, [Tup|Next]) ->
     case element(Pos, Tup) =:= T of
         true -> true;
         false -> member(T, Pos, Next)
     end.

replace(_T, _Pos, [], _New) -> [];
replace(T, Pos, [Tup|Next], New) ->
    case element(Pos, Tup) =:= T of
        true -> [New | Next];
        false -> [Tup | replace(T, Pos, Next, New)]
    end.

delete(_T, _Pos, []) -> [];
delete(T, Pos, [Tup|Next]) ->
    case element(Pos, Tup) =:= T of
        true -> Next;
        false -> [Tup | delete(T, Pos, Next)]
    end.

sort(L) -> eqc_lib:sort(L).
