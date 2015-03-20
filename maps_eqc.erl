-module(maps_eqc).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").

-compile(export_all).

-record(state,
    { contents = [] }).
    
initial_state() -> #state{}.

%% GENERATORS
map_key() -> int().
map_value() -> int().

%% VALUES
%% --------------------------------------------------------------

values() ->
    lists:sort(maps_runner:values()).
    
values_args(_S) -> [].

values_return(#state { contents = C }, []) ->
    lists:sort([V || {_, V} <- C]).

%% UPDATE
%% --------------------------------------------------------------

update_pos(K, V) ->
    M2 = maps_runner:update(K, V),
    lists:sort(maps:to_list(M2)).
    
update_pos_pre(#state { contents = C }) -> C /= [].

update_pos_args(#state { contents = C }) ->
    ?LET(Pair, elements(C),
        [element(1, Pair), map_value()]).
        
update_pos_next(#state { contents = C } = State, _, [K, V]) ->
    State#state { contents = replace_contents(K, V, C) }.

update_pos_return(#state { contents = C}, [K, V]) ->
    lists:sort(replace_contents(K, V, C)).

%% TO_LIST
%% --------------------------------------------------------------

to_list() ->
    L  = maps_runner:to_list(),
    lists:sort(L).
    
to_list_args(_S) -> [].

to_list_return(#state { contents = C }, []) ->
    lists:sort(C).

%% REMOVE
%% --------------------------------------------------------------

remove_pos(K) ->
    ResMap = maps_runner:remove(K),
    lists:sort(maps:to_list(ResMap)).
    
remove_pos_pre(#state { contents = C }) -> C /= [].

remove_pos_args(#state { contents = C }) ->
    ?LET(Pair, elements(C),
        [element(1, Pair)]).
        
remove_pos_next(#state { contents = C } = State, _, [K]) ->
    State#state { contents = del_contents(K, C) }.

remove_pos_return(#state { contents = C }, [K]) ->
    lists:sort(del_contents(K, C)).

%% KEYS
%% --------------------------------------------------------------

keys() ->
    lists:sort(maps_runner:keys()).
    
keys_args(_S) -> [].

keys_return(#state { contents = C }, []) ->
    lists:sort([K || {K, _} <- C]).

%% IS_KEY
%% --------------------------------------------------------------

is_key_pos(K) ->
    maps_runner:is_key(K).
    
is_key_pos_pre(#state { contents = C }) -> C /= [].

is_key_pos_args(#state { contents = C }) ->
    ?LET(Pair, elements(C),
        [element(1, Pair)]).

is_key_pos_return(_S, [_K]) ->
    true.

is_key_neg(K) ->
    maps_runner:is_key(K).
    
is_key_neg_args(#state { contents = C }) ->
    ?SUCHTHAT([K], [map_key()],
        lists:keyfind(K, 1, C) == false).

is_key_neg_pre(#state { contents = C}, [K]) ->
    lists:keyfind(K, 1, C) == false.

is_key_neg_return(_S, [_K]) ->
    false.

%% PUT
%% --------------------------------------------------------------

put(Key, Value) ->
    NewMap = maps_runner:put(Key, Value),
    lists:sort(maps:to_list(NewMap)).
    
put_args(_S) ->
    [map_key(), map_value()].

put_next(#state { contents = C } = State, _, [K, V]) ->
    State#state { contents = add_contents(K, V, C) }.

put_return(#state { contents = C}, [K, V]) ->
    lists:sort(add_contents(K, V, C)).

%% SIZE
%% --------------------------------------------------------------
size() ->
    maps_runner:size().
    
size_args(_S) -> [].

size_return(#state { contents = C }, []) ->
    length(C).
    
%% PROPERTY
%% -------------------------------------------------------------
postcondition_common(S, Call, Res) ->
    eq(Res, return_value(S, Call)).


prop_map() ->
    ?SETUP(fun() ->
        {ok, Pid} = maps_runner:start_link(),
        fun() -> exit(Pid, kill) end
    end,
      ?FORALL(Cmds, more_commands(8, commands(?MODULE)),
        begin
          maps_runner:reset(),
          {H,S,R} = run_commands(?MODULE, Cmds),
          aggregate(command_names(Cmds),
              pretty_commands(?MODULE, Cmds, {H,S,R}, R == ok))
        end)).

%% HELPER ROUTINES
%% -------------------------------------------------------------
add_contents(K, V, C) ->
    lists:keystore(K, 1, C, {K, V}).

del_contents(K, C) ->
    lists:keydelete(K, 1, C).

replace_contents(K, V, C) ->
    lists:keyreplace(K, 1, C, {K, V}).
