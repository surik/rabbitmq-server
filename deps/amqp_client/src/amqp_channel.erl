%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2011 VMware, Inc.  All rights reserved.
%%

%% @doc This module encapsulates the client's view of an AMQP
%% channel. Each server side channel is represented by an amqp_channel
%% process on the client side. Channel processes are created using the
%% {@link amqp_connection} module. Channel processes are supervised
%% under amqp_client's supervision tree.
-module(amqp_channel).

-include("amqp_client.hrl").

-behaviour(gen_server).

-export([call/2, call/3, cast/2, cast/3]).
-export([close/1, close/3]).
-export([next_publish_seqno/1]).
-export([register_return_handler/2, register_flow_handler/2,
         register_confirm_handler/2]).
-export([call_consumer/2]).

-export([start_link/4, connection_closing/3, open/1]).

-export([init/1, terminate/2, code_change/3, handle_call/3, handle_cast/2,
         handle_info/2]).

-define(TIMEOUT_FLUSH, 60000).
-define(TIMEOUT_CLOSE_OK, 3000).

-record(state, {number,
                sup,
                driver,
                rpc_requests        = queue:new(),
                closing             = false, %% false | just_channel |
                                             %%   {connection, Reason}
                writer,
                return_handler_pid  = none,
                confirm_handler_pid = none,
                next_pub_seqno      = 0,
                flow_active         = true,
                flow_handler_pid    = none,
                consumer_module,
                consumer_state,
                start_writer_fun
               }).

%%---------------------------------------------------------------------------
%% Type Definitions
%%---------------------------------------------------------------------------

%% @type amqp_method().
%% This abstract datatype represents the set of methods that comprise
%% the AMQP execution model. As indicated in the overview, the
%% attributes of each method in the execution model are described in
%% the protocol documentation. The Erlang record definitions are
%% autogenerated from a parseable version of the specification. Most
%% fields in the generated records have sensible default values that
%% you need not worry in the case of a simple usage of the client
%% library.

%% @type amqp_msg() = #amqp_msg{}.
%% This is the content encapsulated in content-bearing AMQP methods. It
%% contains the following fields:
%% <ul>
%% <li>props :: class_property() - A class property record, defaults to
%%     #'P_basic'{}</li>
%% <li>payload :: binary() - The arbitrary data payload</li>
%% </ul>

%%---------------------------------------------------------------------------
%% AMQP Channel API methods
%%---------------------------------------------------------------------------

%% @spec (Channel, Method) -> Result
%% @doc This is equivalent to amqp_channel:call(Channel, Method, none).
call(Channel, Method) ->
    gen_server:call(Channel, {call, Method, none}, infinity).

%% @spec (Channel, Method, Content) -> Result
%% where
%%      Channel = pid()
%%      Method = amqp_method()
%%      Content = amqp_msg() | none
%%      Result = amqp_method() | ok | blocked | closing
%% @doc This sends an AMQP method on the channel.
%% For content bearing methods, Content has to be an amqp_msg(), whereas
%% for non-content bearing methods, it needs to be the atom 'none'.<br/>
%% In the case of synchronous methods, this function blocks until the
%% corresponding reply comes back from the server and returns it.
%% In the case of asynchronous methods, the function blocks until the method
%% gets sent on the wire and returns the atom 'ok' on success.<br/>
%% This will return the atom 'blocked' if the server has
%% throttled the  client for flow control reasons. This will return the
%% atom 'closing' if the channel is in the process of shutting down.<br/>
%% Note that for asynchronous methods, the synchronicity implied by
%% 'call' only means that the client has transmitted the method to
%% the broker. It does not necessarily imply that the broker has
%% accepted responsibility for the message.
call(Channel, Method, Content) ->
    gen_server:call(Channel, {call, Method, Content}, infinity).

%% @spec (Channel, Method) -> ok
%% @doc This is equivalent to amqp_channel:cast(Channel, Method, none).
cast(Channel, Method) ->
    gen_server:cast(Channel, {cast, Method, none}).

%% @spec (Channel, Method, Content) -> ok
%% where
%%      Channel = pid()
%%      Method = amqp_method()
%%      Content = amqp_msg() | none
%% @doc This function is the same as {@link call/3}, except that it returns
%% immediately with the atom 'ok', without blocking the caller process.
%% This function is not recommended with synchronous methods, since there is no
%% way to verify that the server has received the method.
cast(Channel, Method, Content) ->
    gen_server:cast(Channel, {cast, Method, Content}).

%% @spec (Channel) -> ok
%% where
%%      Channel = pid()
%% @doc Closes the channel, invokes
%% close(Channel, 200, &lt;&lt;"Goodbye"&gt;&gt;).
close(Channel) ->
    close(Channel, 200, <<"Goodbye">>).

%% @spec (Channel, Code, Text) -> ok
%% where
%%      Channel = pid()
%%      Code = integer()
%%      Text = binary()
%% @doc Closes the channel, allowing the caller to supply a reply code and
%% text.
close(Channel, Code, Text) ->
    gen_server:call(Channel, {close, Code, Text}, infinity).

%% @spec (Channel) -> integer()
%% where
%%      Channel = pid()
%% @doc When in confirm mode, returns the sequence number of the next
%% message to be published.
next_publish_seqno(Channel) ->
    gen_server:call(Channel, next_publish_seqno, infinity).

%% @spec (Channel, ReturnHandler) -> ok
%% where
%%      Channel = pid()
%%      ReturnHandler = pid()
%% @doc This registers a handler to deal with returned messages. The
%% registered process will receive #basic.return{} records.
register_return_handler(Channel, ReturnHandler) ->
    gen_server:cast(Channel, {register_return_handler, ReturnHandler} ).

%% @spec (Channel, ConfirmHandler) -> ok
%% where
%%      Channel = pid()
%%      ConfirmHandler = pid()

%% @doc This registers a handler to deal with confirm-related
%% messages. The registered process will receive #basic.ack{} and
%% #basic.nack{} commands.
register_confirm_handler(Channel, ConfirmHandler) ->
    gen_server:cast(Channel, {register_confirm_handler, ConfirmHandler} ).

%% @spec (Channel, FlowHandler) -> ok
%% where
%%      Channel = pid()
%%      FlowHandler = pid()
%% @doc This registers a handler to deal with channel flow notifications.
%% The registered process will receive #channel.flow{} records.
register_flow_handler(Channel, FlowHandler) ->
    gen_server:cast(Channel, {register_flow_handler, FlowHandler} ).

%% @spec (Channel, Message) -> ok
%% where
%%      Channel = pid()
%%      Message = any()
%% @doc This causes the channel to invoke Consumer:handle_call/2,
%% where Consumer is the amqp_gen_consumer implementation registered with
%% the channel.
call_consumer(Channel, Call) ->
    gen_server:call(Channel, {call_consumer, Call}, infinity).

%%---------------------------------------------------------------------------
%% Internal interface
%%---------------------------------------------------------------------------

%% @private
start_link(Driver, ChannelNumber, Consumer, SWF) ->
    gen_server:start_link(?MODULE,
                          [self(), Driver, ChannelNumber, Consumer, SWF], []).

%% @private
connection_closing(Pid, ChannelCloseType, Reason) ->
    gen_server:cast(Pid, {connection_closing, ChannelCloseType, Reason}).

%% @private
open(Pid) ->
    gen_server:call(Pid, open, infinity).

%%---------------------------------------------------------------------------
%% gen_server callbacks
%%---------------------------------------------------------------------------

%% @private
init([Sup, Driver, ChannelNumber, {ConsumerModule, ConsumerArgs}, SWF]) ->
    State0 = #state{sup              = Sup,
                    driver           = Driver,
                    number           = ChannelNumber,
                    consumer_module  = ConsumerModule,
                    start_writer_fun = SWF},
    {ok, consumer_callback(init, [ConsumerArgs], State0)}.

%% @private
handle_call(open, From, State) ->
    {noreply, rpc_top_half(#'channel.open'{}, none, From, State)};
%% @private
handle_call({close, Code, Text}, From, State) ->
    handle_close(Code, Text, From, State);
%% @private
handle_call({call, Method, AmqpMsg}, From, State) ->
    handle_method_to_server(Method, AmqpMsg, From, State);
%% Handles the delivery of messages from a direct channel
%% @private
handle_call({send_command_sync, Method, Content}, From, State) ->
    Ret = handle_method_from_server(Method, Content, State),
    gen_server:reply(From, ok),
    Ret;
%% Handles the delivery of messages from a direct channel
%% @private
handle_call({send_command_sync, Method}, From, State) ->
    Ret = handle_method_from_server(Method, none, State),
    gen_server:reply(From, ok),
    Ret;
%% @private
handle_call(next_publish_seqno, _From,
            State = #state{next_pub_seqno = SeqNo}) ->
    {reply, SeqNo, State};
%% @private
handle_call({call_consumer, Call}, _From, State) ->
    handle_consumer_callback(handle_call, [Call], State).

%% @private
handle_cast({cast, Method, AmqpMsg}, State) ->
    handle_method_to_server(Method, AmqpMsg, none, State);
%% @private
handle_cast({register_return_handler, ReturnHandler}, State) ->
    erlang:monitor(process, ReturnHandler),
    {noreply, State#state{return_handler_pid = ReturnHandler}};
%% @private
handle_cast({register_confirm_handler, ConfirmHandler}, State) ->
    erlang:monitor(process, ConfirmHandler),
    {noreply, State#state{confirm_handler_pid = ConfirmHandler}};
%% @private
handle_cast({register_flow_handler, FlowHandler}, State) ->
    erlang:monitor(process, FlowHandler),
    {noreply, State#state{flow_handler_pid = FlowHandler}};
%% Received from channels manager
%% @private
handle_cast({method, Method, Content}, State) ->
    handle_method_from_server(Method, Content, State);
%% Handles the situation when the connection closes without closing the channel
%% beforehand. The channel must block all further RPCs,
%% flush the RPC queue (optional), and terminate
%% @private
handle_cast({connection_closing, CloseType, Reason}, State) ->
    handle_connection_closing(CloseType, Reason, State);
%% @private
handle_cast({shutdown, Shutdown}, State) ->
    handle_shutdown(Shutdown, State).

%% Received from rabbit_channel in the direct case
%% @private
handle_info({send_command, Method}, State) ->
    handle_method_from_server(Method, none, State);
%% Received from rabbit_channel in the direct case
%% @private
handle_info({send_command, Method, Content}, State) ->
    handle_method_from_server(Method, Content, State);
%% Received from rabbit_channel in the direct case
%% @private
handle_info({send_command_and_notify, Q, ChPid, Method, Content}, State) ->
    handle_method_from_server(Method, Content, State),
    rabbit_amqqueue:notify_sent(Q, ChPid),
    {noreply, State};
%% This comes from the writer or rabbit_channel
%% @private
handle_info({channel_exit, _ChNumber, Reason}, State) ->
    handle_channel_exit(Reason, State);
%% This comes from rabbit_channel in the direct case
handle_info({channel_closing, ChPid}, State) ->
    ok = rabbit_channel:ready_for_close(ChPid),
    {noreply, State};
%% @private
handle_info(timed_out_flushing_channel, State) ->
    ?LOG_WARN("Channel (~p) closing: timed out flushing while "
              "connection closing~n", [self()]),
    {stop, timed_out_flushing_channel, State};
%% @private
handle_info(timed_out_waiting_close_ok, State) ->
    ?LOG_WARN("Channel (~p) closing: timed out waiting for "
              "channel.close_ok while connection closing~n", [self()]),
    {stop, timed_out_waiting_close_ok, State};
%% @private
handle_info({'DOWN', _, process, ReturnHandler, Reason},
            State = #state{return_handler_pid = ReturnHandler}) ->
    ?LOG_WARN("Channel (~p): Unregistering return handler ~p because it died. "
              "Reason: ~p~n", [self(), ReturnHandler, Reason]),
    {noreply, State#state{return_handler_pid = none}};
%% @private
handle_info({'DOWN', _, process, ConfirmHandler, Reason},
            State = #state{confirm_handler_pid = ConfirmHandler}) ->
    ?LOG_WARN("Channel (~p): Unregistering confirm handler ~p because it died. "
              "Reason: ~p~n", [self(), ConfirmHandler, Reason]),
    {noreply, State#state{confirm_handler_pid = none}};
%% @private
handle_info({'DOWN', _, process, FlowHandler, Reason},
            State = #state{flow_handler_pid = FlowHandler}) ->
    ?LOG_WARN("Channel (~p): Unregistering flow handler ~p because it died. "
              "Reason: ~p~n", [self(), FlowHandler, Reason]),
    {noreply, State#state{flow_handler_pid = none}}.

%% @private
terminate(Reason, State) ->
    consumer_callback(terminate, [Reason], State).

%% @private
code_change(_OldVsn, State, _Extra) ->
    State.

%%---------------------------------------------------------------------------
%% RPC mechanism
%%---------------------------------------------------------------------------

handle_method_to_server(Method, AmqpMsg, From, State) ->
    case {check_invalid_method(Method), From,
          check_block(Method, AmqpMsg, State)} of
        {ok, _, ok} ->
            State1 = case {Method, State#state.next_pub_seqno} of
                         {#'confirm.select'{}, _} ->
                             State#state{next_pub_seqno = 1};
                         {#'basic.publish'{}, 0} ->
                             State;
                         {#'basic.publish'{}, SeqNo} ->
                             State#state{next_pub_seqno = SeqNo + 1};
                         _ ->
                             State
                     end,
            {noreply,
             rpc_top_half(Method, build_content(AmqpMsg), From, State1)};
        {ok, none, BlockReply} ->
            ?LOG_WARN("Channel (~p): discarding method ~p in cast.~n"
                      "Reason: ~p~n", [self(), Method, BlockReply]),
            {noreply, State};
        {ok, _, BlockReply} ->
            {reply, BlockReply, State};
        {{_, InvalidMethodMessage}, none, _} ->
            ?LOG_WARN("Channel (~p): ignoring cast of ~p method. " ++
                      InvalidMethodMessage ++ "~n", [self(), Method]),
            {noreply, State};
        {{InvalidMethodReply, _}, _, _} ->
            {reply, {error, InvalidMethodReply}, State}
    end.

handle_close(Code, Text, From, State) ->
    Close = #'channel.close'{reply_code = Code,
                             reply_text = Text,
                             class_id   = 0,
                             method_id  = 0},
    case check_block(Close, none, State) of
        ok         -> {noreply, rpc_top_half(Close, none, From, State)};
        BlockReply -> {reply, BlockReply, State}
    end.

rpc_top_half(Method, Content, From,
             State0 = #state{rpc_requests = RequestQueue}) ->
    State1 = State0#state{
        rpc_requests = queue:in({From, Method, Content}, RequestQueue)},
    IsFirstElement = queue:is_empty(RequestQueue),
    if IsFirstElement -> do_rpc(State1);
       true           -> State1
    end.

rpc_bottom_half(Reply, State = #state{rpc_requests = RequestQueue}) ->
    {{value, {From, _Method, _Content}}, RequestQueue1} =
        queue:out(RequestQueue),
    case From of none -> ok;
                 _    -> gen_server:reply(From, Reply)
    end,
    do_rpc(State#state{rpc_requests = RequestQueue1}).

do_rpc(State = #state{rpc_requests = Q,
                      closing      = Closing}) ->
    case queue:out(Q) of
        {{value, {From, Method, Content}}, NewQ} ->
            State1 = pre_do(Method, Content, State),
            DoRet = do(Method, Content, State1),
            case ?PROTOCOL:is_method_synchronous(Method) of
                true  -> State1;
                false -> case {From, DoRet} of
                             {none, _} -> ok;
                             {_, ok}   -> gen_server:reply(From, ok)
                             %% Do not reply if error in do. Expecting
                             %% {channel_exit, ...}
                         end,
                         do_rpc(State1#state{rpc_requests = NewQ})
            end;
        {empty, NewQ} ->
            case Closing of
                {connection, Reason} ->
                    gen_server:cast(self(),
                                    {shutdown, {connection_closing, Reason}});
                _ ->
                    ok
            end,
            State#state{rpc_requests = NewQ}
    end.

pending_rpc_method(#state{rpc_requests = Q}) ->
    {value, {_From, Method, _Content}} = queue:peek(Q),
    Method.

pre_do(#'channel.open'{}, _Content, State) ->
    start_writer(State);
pre_do(#'channel.close'{}, _Content, State) ->
    State#state{closing = just_channel};
pre_do(_, _, State) ->
    State.

%%---------------------------------------------------------------------------
%% Handling of methods from the server
%%---------------------------------------------------------------------------

handle_method_from_server(Method, Content, State = #state{closing = Closing}) ->
    case is_connection_method(Method) of
        true -> server_misbehaved(
                    #amqp_error{name        = command_invalid,
                                explanation = "connection method on "
                                              "non-zero channel",
                                method      = element(1, Method)},
                    State);
        false -> Drop = case {Closing, Method} of
                            {just_channel, #'channel.close'{}}    -> false;
                            {just_channel, #'channel.close_ok'{}} -> false;
                            {just_channel, _}                     -> true;
                            _                                     -> false
                        end,
                 if Drop -> ?LOG_INFO("Channel (~p): dropping method ~p from "
                                      "server because channel is closing~n",
                                      [self(), {Method, Content}]),
                            {noreply, State};
                    true -> handle_method_from_server1(Method,
                                                       amqp_msg(Content), State)
                 end
    end.

handle_method_from_server1(#'channel.open_ok'{}, none, State) ->
    {noreply, rpc_bottom_half(ok, State)};
handle_method_from_server1(#'channel.close'{reply_code = Code,
                                            reply_text = Text}, none, State) ->
    do(#'channel.close_ok'{}, none, State),
    {stop, {server_initiated_close, Code, Text}, State};
handle_method_from_server1(#'channel.close_ok'{}, none, State) ->
    {stop, normal, rpc_bottom_half(ok, State)};
handle_method_from_server1(#'basic.consume_ok'{} = ConsumeOk, none, State) ->
    Consume = #'basic.consume'{} = pending_rpc_method(State),
    State1 = consumer_callback(handle_consume_ok, [ConsumeOk, Consume], State),
    {noreply, rpc_bottom_half(ConsumeOk, State1)};
handle_method_from_server1(#'basic.cancel_ok'{} = CancelOk, none, State) ->
    Cancel = #'basic.cancel'{} = pending_rpc_method(State),
    State1 = consumer_callback(handle_cancel_ok, [CancelOk, Cancel], State),
    {noreply, rpc_bottom_half(CancelOk, State1)};
handle_method_from_server1(#'channel.flow'{active = Active} = Flow, none,
                           State = #state{flow_handler_pid = FlowHandler}) ->
    case FlowHandler of none -> ok;
                        _    -> FlowHandler ! Flow
    end,
    %% Putting the flow_ok in the queue so that the RPC queue can be
    %% flushed beforehand. Methods that made it to the queue are not
    %% blocked in any circumstance.
    {noreply, rpc_top_half(#'channel.flow_ok'{active = Active}, none, none,
                           State#state{flow_active = Active})};
handle_method_from_server1(#'basic.deliver'{} = Deliver, AmqpMsg, State) ->
    handle_consumer_callback(handle_deliver, [{Deliver, AmqpMsg}], State);
handle_method_from_server1(
        #'basic.return'{} = BasicReturn, AmqpMsg,
        State = #state{return_handler_pid = ReturnHandler}) ->
    case ReturnHandler of
        none -> ?LOG_WARN("Channel (~p): received {~p, ~p} but there is no "
                          "return handler registered~n",
                          [self(), BasicReturn, AmqpMsg]);
        _    -> ReturnHandler ! {BasicReturn, AmqpMsg}
    end,
    {noreply, State};
handle_method_from_server1(#'basic.cancel'{} = Cancel, none, State) ->
    handle_consumer_callback(handle_cancel, [Cancel], State);
handle_method_from_server1(#'basic.ack'{} = BasicAck, none,
                           #state{confirm_handler_pid = none} = State) ->
    ?LOG_WARN("Channel (~p): received ~p but there is no "
              "confirm handler registered~n", [self(), BasicAck]),
    {noreply, State};
handle_method_from_server1(
        #'basic.ack'{} = BasicAck, none,
        #state{confirm_handler_pid = ConfirmHandler} = State) ->
    ConfirmHandler ! BasicAck,
    {noreply, State};
handle_method_from_server1(#'basic.nack'{} = BasicNack, none,
                           #state{confirm_handler_pid = none} = State) ->
    ?LOG_WARN("Channel (~p): received ~p but there is no "
              "confirm handler registered~n", [self(), BasicNack]),
    {noreply, State};
handle_method_from_server1(
        #'basic.nack'{} = BasicNack, none,
        #state{confirm_handler_pid = ConfirmHandler} = State) ->
    ConfirmHandler ! BasicNack,
    {noreply, State};

handle_method_from_server1(Method, none, State) ->
    {noreply, rpc_bottom_half(Method, State)};
handle_method_from_server1(Method, Content, State) ->
    {noreply, rpc_bottom_half({Method, Content}, State)}.

%%---------------------------------------------------------------------------
%% Other handle_* functions
%%---------------------------------------------------------------------------

handle_connection_closing(CloseType, Reason,
                          State = #state{rpc_requests = RpcQueue,
                                         closing      = Closing}) ->
    NewState = State#state{closing = {connection, Reason}},
    case {CloseType, Closing, queue:is_empty(RpcQueue)} of
        {flush, false, false} ->
            erlang:send_after(?TIMEOUT_FLUSH, self(),
                              timed_out_flushing_channel),
            {noreply, NewState};
        {flush, just_channel, false} ->
            erlang:send_after(?TIMEOUT_CLOSE_OK, self(),
                              timed_out_waiting_close_ok),
            {noreply, NewState};
        _ ->
            handle_shutdown({connection_closing, Reason}, NewState)
    end.

handle_channel_exit(Reason, State) ->
    case Reason of
        %% Sent by rabbit_channel in the direct case
        #amqp_error{name = ErrorName, explanation = Expl} ->
            ?LOG_WARN("Channel (~p) closing: server sent error ~p~n",
                      [self(), Reason]),
            {IsHard, Code, _} = ?PROTOCOL:lookup_amqp_exception(ErrorName),
            {stop, if IsHard -> {connection_closing,
                                 {server_initiated_hard_close, Code, Expl}};
                      true   -> {server_initiated_close, Code, Expl}
                   end, State};
        %% Unexpected death of a channel infrastructure process
        _ ->
            {stop, {infrastructure_died, Reason}, State}
    end.

handle_shutdown({_, 200, _}, State) ->
    {stop, normal, State};
handle_shutdown({connection_closing, normal}, State) ->
    {stop, normal, State};
handle_shutdown(Reason, State) ->
    {stop, Reason, State}.

%%---------------------------------------------------------------------------
%% Internal plumbing
%%---------------------------------------------------------------------------

do(Method, Content, #state{driver = Driver, writer = W}) ->
    %% Catching because it expects the {channel_exit, _, _} message on error
    catch case {Driver, Content} of
              {network, none} -> rabbit_writer:send_command_sync(W, Method);
              {network, _}    -> rabbit_writer:send_command_sync(W, Method,
                                                                 Content);
              {direct, none}  -> rabbit_channel:do(W, Method);
              {direct, _}     -> rabbit_channel:do(W, Method, Content)
          end.

start_writer(State = #state{start_writer_fun = SWF}) ->
    {ok, Writer} = SWF(),
    State#state{writer = Writer}.

amqp_msg(none) ->
    none;
amqp_msg(Content) ->
    {Props, Payload} = rabbit_basic:from_content(Content),
    #amqp_msg{props = Props, payload = Payload}.

build_content(none) ->
    none;
build_content(#amqp_msg{props = Props, payload = Payload}) ->
    rabbit_basic:build_content(Props, Payload).

check_block(_Method, _AmqpMsg, #state{closing = just_channel}) ->
    closing;
check_block(_Method, _AmqpMsg, #state{closing = {connection, _}}) ->
    closing;
check_block(_Method, none, #state{}) ->
    ok;
check_block(_Method, #amqp_msg{}, #state{flow_active = false}) ->
    blocked;
check_block(_Method, _AmqpMsg, #state{}) ->
    ok.

check_invalid_method(#'channel.open'{}) ->
    {use_amqp_connection_module,
     "Use amqp_connection:open_channel/{1,2} instead"};
check_invalid_method(#'channel.close'{}) ->
    {use_close_function, "Use close/{1,3} instead"};
check_invalid_method(Method) ->
    case is_connection_method(Method) of
        true  -> {connection_methods_not_allowed,
                  "Sending connection methods is not allowed"};
        false -> ok
    end.

is_connection_method(Method) ->
    {ClassId, _} = ?PROTOCOL:method_id(element(1, Method)),
    ?PROTOCOL:lookup_class_name(ClassId) == connection.

server_misbehaved(#amqp_error{} = AmqpError, State = #state{number = Number}) ->
    case rabbit_binary_generator:map_exception(Number, AmqpError, ?PROTOCOL) of
        {0, _} ->
            {stop, {server_misbehaved, AmqpError}, State};
        {_, Close} ->
            ?LOG_WARN("Channel (~p) flushing and closing due to soft "
                      "error caused by the server ~p~n", [self(), AmqpError]),
            Self = self(),
            spawn(fun () -> call(Self, Close) end),
            {noreply, State}
    end.

handle_consumer_callback(handle_call, Args,
                         State = #state{consumer_state = CState,
                                        consumer_module = CModule}) ->
    {reply, Reply, NewCState} =
        erlang:apply(CModule, handle_call, Args ++ [CState]),
    {reply, Reply, State#state{consumer_state = NewCState}};
handle_consumer_callback(Function, Args, State) ->
    {noreply, consumer_callback(Function, Args, State)}.

consumer_callback(init, Args, State = #state{}) ->
    consumer_callback_basic(init, Args, State);
consumer_callback(terminate, Args, State = #state{consumer_state = CState,
                                                  consumer_module = CModule}) ->
    erlang:apply(CModule, terminate, Args ++ [CState]),
    State;
consumer_callback(Function, Args, State = #state{consumer_state = CState}) ->
    consumer_callback_basic(Function, Args ++ [CState], State).

consumer_callback_basic(Function,
                        Args, State = #state{consumer_module = CModule}) ->
    {ok, NewCState} = erlang:apply(CModule, Function, Args),
    State#state{consumer_state = NewCState}.
