%%%
%%%    Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@mydlp.com>
%%%
%%%--------------------------------------------------------------------------
%%%    This file is part of MyDLP.
%%%
%%%    MyDLP is free software: you can redistribute it and/or modify
%%%    it under the terms of the GNU General Public License as published by
%%%    the Free Software Foundation, either version 3 of the License, or
%%%    (at your option) any later version.
%%%
%%%    MyDLP is distributed in the hope that it will be useful,
%%%    but WITHOUT ANY WARRANTY; without even the implied warranty of
%%%    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%%    GNU General Public License for more details.
%%%
%%%    You should have received a copy of the GNU General Public License
%%%    along with MyDLP.  If not, see <http://www.gnu.org/licenses/>.
%%%--------------------------------------------------------------------------

%%%-------------------------------------------------------------------
%%% @author H. Kerem Cevahir <kerem@mydlp.com>
%%% @copyright 2011, H. Kerem Cevahir
%%% @doc Worker for mydlp.
%%% @end
%%%-------------------------------------------------------------------

-module(mydlp_pool).
-author("kerem@mydlp.com").
-behaviour(gen_server).

-include("mydlp.hrl").

%% API
-export([start_link/2,
	call/2,
	call/3,
	cast/2,
	cast/3,
	set_pool_size/2,
	get_pool_size/1,
	stop/1]).

%% gen_server callbacks
-export([init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3]).

-include_lib("eunit/include/eunit.hrl").

-record(state, {
	module_name,
	inactive,
	workers,
	pool_size
}).

%%%%%%%%%%%%%  API

get_pool_size(ModuleName) -> gen_server:call(ModuleName, get_pool_size).

set_pool_size(ModuleName, PoolSize) -> gen_server:cast(ModuleName, {set_pool_size, PoolSize}).

call(ModuleName, Request) -> call(ModuleName, Request, 5000).

call(ModuleName, Request, Timeout) -> gen_server:call(ModuleName, {call, Request, Timeout}, Timeout).

cast(ModuleName, Request) -> cast(ModuleName, Request, 5000).

cast(ModuleName, Request, Timeout) -> gen_server:cast(ModuleName, {call, Request, Timeout}).

start_link(ModuleName, PoolSize) ->
	case gen_server:start_link({local, ModuleName}, ?MODULE, [ModuleName, PoolSize], []) of
		{ok, Pid} -> {ok, Pid};
		{error, {already_started, Pid}} -> {ok, Pid}
	end.

stop(ModuleName) ->
	gen_server:call(ModuleName, stop).

%%%%%%%%%%%%%% gen_server handles

handle_request(Type, Request, Timeout, #state{inactive=IQ, module_name=ModuleName} = State) ->
	Parent = self(),
	InactiveQ = case queue:out(IQ) of
		{{value, Pid}, IQ1} -> ?ASYNC(fun() ->
					Result = try execute(Type, Pid, Request, Timeout - 500)
						catch Class:Error -> 
							?ERROR_LOG("An error occurred when dispatcing pool req. Type: "?S", Request: "?S", Pid: "?S"~nClass: "?S", Error: "?S"~nStacktrace:"?S, 
								[Type, Request, Pid, Class, Error, erlang:get_stacktrace()]),
							{ierror, Class, Error} end,
					return_result(Parent, Type, Pid, Result)
				end, Timeout - 250), IQ1;
		{empty, IQ1} -> ?ERROR_LOG("Pool ("?S") is exhausted. Waiting for to dispatch request. Request: "?S, [ModuleName, Request]),
				?ASYNC(fun() ->
					case Timeout > 1000 of
						true ->	timer:sleep(500),
							reschedule(ModuleName, Type, Request, Timeout - 500);
						false -> ok end
				end, 1000),
				IQ1 end,

	{noreply, State#state{inactive=InactiveQ}}.

handle_call({call, Request, Timeout}, From, State) -> handle_request({call, From}, Request, Timeout, State);

handle_call(get_pool_size, _From, #state{pool_size=PoolSize} = State) ->
	{reply, PoolSize, State};

handle_call(stop, _From, State) ->
	{stop, normalStop, State};

handle_call(_Msg, _From, State) ->
	{noreply, State}.

handle_cast({cast, Request, Timeout}, State) -> handle_request(cast, Request, Timeout, State);

handle_cast({reschedule, Type, Request, Timeout}, State) -> handle_request(Type, Request, Timeout, State);

handle_cast({set_pool_size, PoolSize},  State) ->
	State1 = State#state{pool_size=PoolSize},
	State2 = start_workers(State1),
	{noreply, State2};

handle_cast(_Msg, State) ->
	{noreply, State}.

handle_info({async_reply, Reply, From}, State) ->
	gen_server:reply(From, Reply),
	{noreply, State};

handle_info({inactivate, Pid}, #state{inactive=IQ} = State) ->
	IQ1 = queue:in(Pid, IQ),
	{noreply, State#state{inactive=IQ1}};

handle_info({'EXIT', FromPid, _Reason}, #state{module_name=ModuleName} = State) ->
	?ERROR_LOG("A worker ("?S") from pool ("?S") is dead. Recreating a worker.", [FromPid, ModuleName]),
	State1 = release_worker(FromPid, State),
	State2 = start_workers(State1),
	{noreply, State2};

handle_info(_Info, State) ->
	{noreply, State}.

%%%%%%%%%%%%%%%% Implicit functions

init([ModuleName, PoolSize]) ->
	State = #state{inactive=queue:new(), module_name=ModuleName, pool_size=PoolSize, workers=[]},
	process_flag(trap_exit, true),
	State1 = start_workers(State),
	{ok, State1}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%%%%%%%%%%%%%%%% internal

start_workers(#state{pool_size=PoolSize, workers=Workers} = State) ->
	NumOfWorkers = length(Workers),
	case NumOfWorkers >= PoolSize of
		false -> case start_worker(State) of
				{S1, {ok, _Pid}} -> start_workers(S1);
				{_S1, Else} -> throw({error, {can_not_start_worker, Else}}) end;
		true -> State end.

start_worker(#state{module_name=ModuleName, inactive=IQ, workers=WL} = State) ->
	case gen_server:start_link(ModuleName, [], []) of
		{ok, Pid} ->
			WL1 = lists:umerge(WL, [Pid]),
			IQ1 = queue:in(Pid, IQ),
			{State#state{inactive=IQ1, workers=WL1}, {ok, Pid}};
		Else -> ?ERROR_LOG("Worker didn't start. ReturnVal: "?S". State: "?S, [Else, State]),
			{State, Else} end.

release_worker(FromPid, #state{inactive=IQ, workers=WL} = State) ->
	WL1 = lists:delete(FromPid, WL),
	
	QL = queue:to_list(IQ),
	QL1 = lists:delete(FromPid, QL),
	IQ1 = queue:from_list(QL1),

	State#state{inactive=IQ1, workers=WL1}.

execute(cast, Pid, Request, _Timeout) -> gen_server:cast(Pid, Request);
execute({call, _From}, Pid, Request, Timeout) -> gen_server:call(Pid, Request, Timeout).

return_result(Parent, {call, From}, Pid, Result) ->
	Parent ! {async_reply, Result, From},
	return_result1(Parent, Pid);
return_result(Parent, _Type, Pid, _Result) ->
	return_result1(Parent, Pid).

return_result1(Parent, Pid) ->
	Parent ! {inactivate, Pid}.

reschedule(ModuleName, Type, Request, Timeout) -> gen_server:cast(ModuleName, {reschedule, Type, Request, Timeout}).
