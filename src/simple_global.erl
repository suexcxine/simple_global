%%%-------------------------------------------------------------------
%%% @author suexcxine <suex.bestwishes@gmail.com>
%%% @doc
%%%   A simple gen_server callback module for global name register.
%%%   Eventual consistency for simplicity and performance.
%%%   One process is allowed to have multiple names.
%%%   Processes are only allowed to register/unregister from their own nodes, for consistency.
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(simple_global).
-author("suex.bestwishes@gmail.com").
-behaviour(gen_server).

%% API
-export([start_link/0, start/0]).
-export([whereis_name/1, register_name/2, unregister_name/1, send/2, set_meta/2, set_priority/1]).
-export([local_registered_names/0, local_registered_info/0, registered_names/0, registered_info/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start() ->
    gen_server:start({local, ?SERVER}, ?MODULE, [], []).

%% dirty read ets
whereis_name(Name) ->
    case ets:lookup(?ETS, Name) of
        [{_, Pid, _, _, _}] -> Pid;
        _ -> undefined
    end.

register_name(Name, Pid) ->
    gen_server:call(?SERVER, {register, Name, Pid}).

unregister_name(Name) ->
    gen_server:call(?SERVER, {unregister, Name}).

send(Name, Msg) ->
    case whereis_name(Name) of
        undefined -> ok;
        Pid -> Pid ! Msg
    end.

set_meta(Name, Meta) ->
    gen_server:call(?SERVER, {set_meta, Name, Meta}).

set_priority(Priority) ->
    gen_server:call(?SERVER, {set_priority, Priority}).

local_registered_names() ->
    Ms = [{{'$1', '_', '$3', '_', '_'}, [{'=:=', '$3', local}], ['$1']}],
    ets:select(?ETS, Ms).

local_registered_info() ->
    Ms = [{{'$1', '$2', '$3', '_', '$4'}, [{'=:=', '$3', local}], [{{'$1', '$2', '$4'}}]}],
    ets:select(?ETS, Ms).

registered_names() ->
    Ms = [{{'$1', '_', '$3', '_', '_'}, [], ['$1']}],
    ets:select(?ETS, Ms).

registered_info() ->
    Ms = [{{'$1', '$2', '$3', '_', '_'}, [], [{{'$1', '$2'}}]}],
    ets:select(?ETS, Ms).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% state:
%% #{
%%   peers => #{pid => MRef}
%% }
init([]) ->
    process_flag(trap_exit, true),
    ok = net_kernel:monitor_nodes(true),
    broadcast([{?SERVER, Node} || Node <- nodes()], {sync_req, self()}),
    ets:new(?ETS, [ordered_set, named_table, public, {keypos, 1}, {read_concurrency, true}]),
    {ok, #{peers => #{}}}.

handle_call({register, Name, Pid}, _From, #{peers := Peers} = State) ->
    Result = case node(Pid) =:= node() of
        true ->
            case ets:member(?ETS, Name) of
                true ->
                    % this name is already registered
                    no;
                false ->
                    MRef = erlang:monitor(process, Pid),
                    ets:insert(?ETS, {Name, Pid, local, MRef, #{}}),
                    ets:insert(?ETS, {{ref, MRef}, Name}),
                    broadcast(maps:keys(Peers), {register_notify, self(), Name, Pid}),
                    yes
            end;
        false ->
            % only local process registration is allowed
            no
    end,
    {reply, Result, State};

handle_call({unregister, Name}, _From, #{peers := Peers} = State) ->
    case ets:lookup(?ETS, Name) of
        [{_, _Pid, local, MRef, _}] ->
            ets:delete(?ETS, {ref, MRef}),
            ets:delete(?ETS, Name),
            erlang:demonitor(MRef),
            broadcast(maps:keys(Peers), {unregister_notify, self(), Name}),
            ok;
        _ ->
            % only local process unregistration is allowed, to guarantee consistency
            ok
    end,
    {reply, ok, State};

handle_call({set_meta, Name, Meta}, _From, #{peers := Peers} = State) ->
    case ets:lookup(?ETS, Name) of
        [{_, Pid, local, MRef, _}] ->
            ets:insert(?ETS, {Name, Pid, local, MRef, Meta}),
            broadcast(maps:keys(Peers), {add_meta_notify, self(), Name, Meta}),
            ok;
        _ ->
            % only local process is allowed, to guarantee consistency
            ok
    end,
    {reply, ok, State};

handle_call({set_priority, Priority}, _From, State) ->
    Result = (catch process_flag(priority, Priority)),
    {reply, Result, State};

handle_call(Request, _From, State) ->
    logger:warning("simple_global received unknown call msg: ~p~n", [Request]),
    {reply, ok, State}.

handle_cast({sync_resp, Peer, Regs}, #{peers := Peers} = State) ->
    % logger:debug("got sync_resp from peer: ~p, regs: ~p~n", [node(Peer), Regs]),
    % receive reg data from peer
    lists:foreach(fun
        ({Name, Pid}) ->
            on_remote_reg_notify(Name, Pid);
        ({Name, Pid, Meta}) ->
            on_remote_reg_notify(Name, Pid, Meta)
    end, Regs),
    % do we know this peer ?
    case maps:is_key(Peer, Peers) of
        true ->
            {noreply, State};
        false ->
            MRef = erlang:monitor(process, Peer),
            {noreply, State#{peers => Peers#{Peer => MRef}}}
    end;

handle_cast(Msg, State) ->
    logger:warning("simple_global received unknown cast msg: ~p~n", [Msg]),
    {noreply, State}.

handle_info({register_notify, Peer, Name, Pid}, #{peers := Peers} = State) ->
    case maps:find(Peer, Peers) of
        {ok, _} ->
            on_remote_reg_notify(Name, Pid);
        _ ->
            % from unknown peer
            logger:warning("simple_global: register_notify msg from unknown peer: ~p~n", [{Peer, Name, Pid}]),
            ok
    end,
    {noreply, State};

handle_info({unregister_notify, Peer, Name}, #{peers := Peers} = State) ->
    case maps:find(Peer, Peers) of
        {ok, _} ->
            on_remote_unreg_notify(Name, node(Peer));
        _ ->
            % from unknown peer
            logger:warning("simple_global: unregister_notify msg from unknown peer: ~p~n", [{Peer, Name}]),
            ok
    end,
    {noreply, State};

handle_info({add_meta_notify, Peer, Name, Meta}, #{peers := Peers} = State) ->
    case maps:find(Peer, Peers) of
        {ok, _} ->
            on_remote_addmeta_notify(Name, node(Peer), Meta);
        _ ->
            % from unknown peer
            logger:warning("simple_global: addmeta_notify msg from unknown peer: ~p~n", [{Peer, Name}]),
            ok
    end,
    {noreply, State};

handle_info({sync_req, Peer}, #{peers := Peers} = State) ->
    gen_server:cast(Peer, {sync_resp, self(), local_registered_info()}),
    % do we know this peer ?
    case maps:is_key(Peer, Peers) of
        true ->
            {noreply, State};
        false ->
            MRef = monitor(process, Peer),
            erlang:send(Peer, {sync_req, self()}),
            {noreply, State#{peers => Peers#{Peer => MRef}}}
    end;

handle_info({'DOWN', MRef, process, Pid, _Info}, #{peers := Peers} = State) when node(Pid) =:= node() ->
    % local registered process is down
    case ets:lookup(?ETS, {ref, MRef}) of
        [{_, Name}] ->
            ets:delete(?ETS, {ref, MRef}),
            case ets:lookup(?ETS, Name) of
                [{_, Pid, _, MRef, _}] ->
                    ets:delete(?ETS, Name),
                    broadcast(maps:keys(Peers), {unregister_notify, self(), Name}),
                    ok;
                _ ->
                    % this name maybe overwritten by remote register, so pid doesn't match
                    ok
            end;
        _ ->
            % maybe demonitored
            ok
    end,
    {noreply, State};

handle_info({'DOWN', _MRef, process, Pid, _Info}, #{peers := Peers} = State) ->
    % remote simple_global process is down
    case maps:take(Pid, Peers) of
        {_, LeftPeers} ->
            Node = node(Pid),
            Ms = [{{'_', '_', '$1', '_', '_'}, [{'=:=', '$1', Node}], [true]}],
            ets:select_delete(?ETS, Ms),
            % we don't need to clear ref records
            % since only local registration have those ref records
            {noreply, State#{peers => LeftPeers}};
        _ ->
            {noreply, State}
    end;

%% nodeup: discover if there is a peer
handle_info({nodeup, Node}, State) ->
    erlang:send({?SERVER, Node}, {sync_req, self()}),
    {noreply, State};

%% we do nothing here, since there would be a DOWN message of simple_global peer process
handle_info({nodedown, _Node}, State) ->
    {noreply, State};

handle_info(Info, State) ->
    logger:warning("simple_global received unknown info msg: ~p~n", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

on_remote_reg_notify(Name, Pid) ->
    on_remote_reg_notify(Name, Pid, #{}).

on_remote_reg_notify(Name, Pid, Meta) ->
    case ets:lookup(?ETS, Name) of
        [{_, OldPid, _, _, _}] when Pid =/= OldPid ->
            % name clash
            resolve_nameclash(Name, OldPid, Pid, Meta);
        _ ->
            % no reference for remote process, since it's not monitored locally
            % so, just place an undefined
            ets:insert(?ETS, {Name, Pid, node(Pid), undefined, Meta}),
            ok
    end.

on_remote_unreg_notify(Name, Node) ->
    case ets:lookup(?ETS, Name) of
        [{_, _Pid, Node, _, _}] when Node =/= local ->
            ets:delete(?ETS, Name),
            ok;
        _ ->
            % unreg notify from wrong node, ignore
            ok
    end.

on_remote_addmeta_notify(Name, Node, Meta) ->
    case ets:lookup(?ETS, Name) of
        [{_, Pid, Node, _, _}] when Node =/= local ->
            ets:insert(?ETS, {Name, Pid, node(Pid), undefined, Meta}),
            ok;
        _ ->
            % addmeta notify from wrong node, ignore
            ok
    end.

resolve_nameclash(Name, OldPid, Pid, Meta) when node(Pid) < node(OldPid) ->
    case node(OldPid) =:= node() of
        true ->
            % old pid is registered locally
            % kill old one according to our rule
            % we can expect a DOWN msg to do cleaning for this kill
            logger:error("simple_global: Name conflict, terminating ~p~n", [{Name, OldPid}]),
            exit(OldPid, kill);
        false ->
            ok
    end,
    % no reference for remote process, since it's not monitored locally
    ets:insert(?ETS, {Name, Pid, node(Pid), undefined, Meta}),
    ok;
resolve_nameclash(_Name, _OldPid, _Pid, _Meta) ->
    % just ignore, since we are right
    % let other sides do something
    ok.

broadcast(Peers, Msg) ->
    lists:foreach(fun(I) -> erlang:send(I, Msg) end, Peers).

