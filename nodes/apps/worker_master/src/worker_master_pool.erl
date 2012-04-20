%% -*- mode: erlang -*-
%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% Copyright 2011 Benjamin Nortier
%%
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%
%%       http://www.apache.org/licenses/LICENSE-2.0
%%
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
-module(worker_master_pool).
-author('Benjamin Nortier <bjnortier@gmail.com>').
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([start_link/0, stop/0, get_worker/1, put_worker/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%                              Public API                                  %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% @doc Start the master worker pool
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({global, ?MODULE}, ?MODULE, [], []).

%% @doc Stop the master pool
-spec stop() -> ok.
stop() ->
    gen_server:call(global:whereis_name(?MODULE), stop).

%% @doc Get a worker, and wait for the given time if none are available
%%      immediately.
-spec get_worker(MaxWait::integer()) -> pid() | {error, no_worker_available}.
get_worker(MaxWaitSecs) ->
    case gen_server:call(global:whereis_name(?MODULE), {get_worker, self(), MaxWaitSecs}) of
	{worker, Worker} ->
	    Worker;
	waiting ->
	    receive
		{worker, Pid} ->
		    Pid;
		no_worker_available ->
		    {error, no_worker_available}
	    end
    end.

%% @doc Stop the master pool
-spec put_worker(Worker :: pid()) -> ok.
put_worker(Worker) ->
    gen_server:call(global:whereis_name(?MODULE), {put_worker, Worker}).


%% call(WorkerPid, Msg) ->
%%     case catch(worker_process:call(WorkerPid, Msg)) of
%% 	{'EXIT', {{error, Reason}, _}} ->
%% 	    {error, Reason};
%% 	Result ->
%% 	    Result
%%     end.


%% ===================================================================
%% gen_server
%% ===================================================================

-record(state, {available, waiting}).

init([]) ->
    _ = spawn_link(fun() -> waiting_process_loop() end),
    {ok, #state{available = queue:new(), waiting = queue:new()}}.

handle_call({get_worker, Caller, MaxWaitSecs}, _From, State = #state{ available = Available,
								      waiting   = Waiting }) ->
    case queue:out(Available) of
	{empty, _} ->
	    {reply, waiting, State#state{ waiting = queue:in({MaxWaitSecs, Caller}, Waiting) }};
	{{value, {MonitorRef, Worker}}, Remaining} ->
	    true = demonitor(MonitorRef),
	    {reply, {worker, Worker}, State#state{ available = Remaining }}
    end;
handle_call({put_worker, Worker}, _From, State) ->
    case is_process_alive(Worker) of
	true ->		
	    State1 = send_to_waiting_or_add_to_available(Worker, State),
	    {reply, ok, State1}; 
	false ->
	    lager:warning("Cannot put dead worker: ~p", [Worker]),
	    {reply, ok, State}
    end;
handle_call(stop, _From, State) ->
    {stop, normal, stopped, State};
handle_call(Request, _From, State) ->
    lager:warning("~p unknown call: ~p~n", [?MODULE, Request]),
    {reply, unknown_call, State}.

handle_cast(timeout_waiting_processes,  State = #state{ waiting = WaitingQueue }) ->
    %% Decrement the waiting seconds, or remove the 
    %% process if there is no time remaining
    WaitingQueue1 = queue:filter(
		      fun({0, WaitingPid}) ->
			      WaitingPid ! no_worker_available,
			      false;
			 ({SecsRemaining, WaitingPid}) ->
				[{SecsRemaining - 1, WaitingPid}]
		      end,
		      WaitingQueue),
    {noreply, State#state{ waiting = WaitingQueue1 }};
handle_cast(Msg, State) ->
    lager:warning("~p unknown cast: ~p~n", [?MODULE, Msg]),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, DeadPid, _}, State = #state{ available = Available }) ->
    lager:warning("Worker ~p died whilst in available queue", [DeadPid]),
    Available1 = queue:filter(fun({_MonitorRef, Worker}) when Worker =:= DeadPid ->
				      false;
				 (_) ->
				      true
			      end,
			      Available),
    {noreply, State#state{ available = Available1 }};
handle_info(Info, State) ->
    lager:warning("~p unknown info: ~p~n", [?MODULE, Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% gen_server
%% ===================================================================

%% @doc Send to the first waiting process if there are any, otherwise
%%      add to available workers
send_to_waiting_or_add_to_available(Worker, State = #state{ available = Available,
							    waiting   = Waiting }) ->
    case queue:out(Waiting) of
	{empty, _} ->
	    lager:info("worker ~p available", [Worker]),
	    MonitorRef = monitor(process, Worker),
	    State#state{ available = queue:in({MonitorRef, Worker}, Available) };
	{{value, {_WaitSecs, Waiting}}, LeftWaiting} ->
	    lager:info("worker ~p to waiting process ~p", [Worker, Waiting]),
	    Waiting ! {worker, Worker},
	    State#state{ waiting = LeftWaiting }
    end.

waiting_process_loop() ->
    timer:sleep(1000),
    gen_server:cast(global:whereis_name(?MODULE), timeout_waiting_processes),
    waiting_process_loop().
