%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_connector_mqtt).

-include_lib("typerefl/include/types.hrl").
-include_lib("emqx_resource/include/emqx_resource_behaviour.hrl").

-behaviour(supervisor).

%% API and callbacks for supervisor
-export([ start_link/0
        , init/1
        , create_bridge/1
        , drop_bridge/1
        , bridges/0
        ]).

%% callbacks of behaviour emqx_resource
-export([ on_start/2
        , on_stop/2
        , on_query/4
        , on_health_check/2
        ]).

-behaviour(hocon_schema).

-export([ roots/0
        , fields/1]).

%%=====================================================================
%% Hocon schema
roots() ->
    [{config, #{type => hoconsc:ref(?MODULE, "config")}}].

fields("config") ->
    emqx_connector_mqtt_schema:fields("config").

%% ===================================================================
%% supervisor APIs
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    SupFlag = #{strategy => one_for_one,
                intensity => 100,
                period => 10},
    {ok, {SupFlag, []}}.

bridge_spec(Config) ->
    #{id => maps:get(name, Config),
      start => {emqx_connector_mqtt_worker, start_link, [Config]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [emqx_connector_mqtt_worker]}.

-spec(bridges() -> [{node(), map()}]).
bridges() ->
    [{Name, emqx_connector_mqtt_worker:status(Name)}
     || {Name, _Pid, _, _} <- supervisor:which_children(?MODULE)].

create_bridge(Config) ->
    supervisor:start_child(?MODULE, bridge_spec(Config)).

drop_bridge(Name) ->
    case supervisor:terminate_child(?MODULE, Name) of
        ok ->
            supervisor:delete_child(?MODULE, Name);
        {error, Error} ->
            {error, Error}
    end.

%% ===================================================================
on_start(InstId, Conf) ->
    logger:info("starting mqtt connector: ~p, ~p", [InstId, Conf]),
    NamePrefix = binary_to_list(InstId),
    BasicConf = basic_config(Conf),
    InitRes = {ok, #{name_prefix => NamePrefix, baisc_conf => BasicConf, sub_bridges => []}},
    InOutConfigs = check_channel_id_dup(maps:get(ingress_channels, Conf, [])
                                        ++ maps:get(egress_channels, Conf, [])),
    lists:foldl(fun
            (_InOutConf, {error, Reason}) ->
                {error, Reason};
            (InOutConf, {ok, #{sub_bridges := SubBridges} = Res}) ->
                case create_channel(InOutConf, NamePrefix, BasicConf) of
                    {error, Reason} -> {error, Reason};
                    {ok, Name} -> {ok, Res#{sub_bridges => [Name | SubBridges]}}
                end
        end, InitRes, InOutConfigs).

on_stop(InstId, #{sub_bridges := NameList}) ->
    logger:info("stopping mqtt connector: ~p", [InstId]),
    lists:foreach(fun(Name) ->
            remove_channel(Name)
        end, NameList).

%% TODO: let the emqx_resource trigger on_query/4 automatically according to the
%%  `ingress_channels` and `egress_channels` config
on_query(_InstId, {create_channel, Conf}, _AfterQuery, #{name_prefix := Prefix,
        baisc_conf := BasicConf}) ->
    create_channel(Conf, Prefix, BasicConf);
on_query(InstId, {publish_to_local, Msg}, _AfterQuery, _State) ->
    logger:debug("publish to local node, connector: ~p, msg: ~p", [InstId, Msg]);
on_query(InstId, {publish_to_remote, Msg}, _AfterQuery, _State) ->
    logger:debug("publish to remote node, connector: ~p, msg: ~p", [InstId, Msg]).

on_health_check(_InstId, #{sub_bridges := NameList} = State) ->
    Results = [{Name, emqx_connector_mqtt_worker:ping(Name)} || Name <- NameList],
    case lists:all(fun({_, pong}) -> true; ({_, _}) -> false end, Results) of
        true -> {ok, State};
        false -> {error, {some_sub_bridge_down, Results}, State}
    end.

check_channel_id_dup(Confs) ->
    lists:foreach(fun(#{id := Id}) ->
            case length([Id || #{id := Id0} <- Confs, Id0 == Id]) of
                1 -> ok;
                L when L > 1 -> error({mqtt_bridge_conf, {duplicate_id_found, Id}})
            end
        end, Confs),
    Confs.

%% this is an `ingress_channels` bridge
create_channel(#{subscribe_remote_topic := RemoteT, local_topic := LocalT, id := Id} = InConf,
        NamePrefix, BasicConf) ->
    Name = bridge_name(NamePrefix, Id),
    logger:info("creating ingress channel ~p, remote ~s -> local ~s",
        [Name, RemoteT, LocalT]),
    create_sub_bridge(BasicConf#{
        name => Name,
        clientid => clientid(Id),
        subscriptions => InConf, forwards => undefined});
%% this is an `egress_channels` bridge
create_channel(#{subscribe_local_topic := LocalT, remote_topic := RemoteT, id := Id} = OutConf,
        NamePrefix, BasicConf) ->
    Name = bridge_name(NamePrefix, Id),
    logger:info("creating egress channel ~p, local ~s -> remote ~s",
        [Name, LocalT, RemoteT]),
    create_sub_bridge(BasicConf#{
        name => bridge_name(NamePrefix, Id),
        clientid => clientid(Id),
        subscriptions => undefined, forwards => OutConf}).

remove_channel(BridgeName) ->
    logger:info("removing channel ~p", [BridgeName]),
    case ?MODULE:drop_bridge(BridgeName) of
        ok -> ok;
        {error, not_found} -> ok;
        {error, Reason} ->
            logger:error("stop channel ~p failed, error: ~p", [BridgeName, Reason])
    end.

create_sub_bridge(#{name := Name} = Conf) ->
    case ?MODULE:create_bridge(Conf) of
        {ok, _Pid} ->
            start_sub_bridge(Name);
        {error, {already_started, _Pid}} ->
            {ok, Name};
        {error, Reason} ->
            {error, Reason}
    end.

start_sub_bridge(Name) ->
    case emqx_connector_mqtt_worker:ensure_started(Name) of
        ok -> {ok, Name};
        {error, Reason} -> {error, Reason}
    end.

basic_config(#{
        server := Server,
        reconnect_interval := ReconnIntv,
        proto_ver := ProtoVer,
        bridge_mode := BridgeMod,
        username := User,
        password := Password,
        clean_start := CleanStart,
        keepalive := KeepAlive,
        retry_interval := RetryIntv,
        max_inflight := MaxInflight,
        replayq := ReplayQ,
        ssl := #{enable := EnableSsl} = Ssl}) ->
    #{
        replayq => ReplayQ,
        %% connection opts
        server => Server,
        reconnect_interval => ReconnIntv,
        proto_ver => ProtoVer,
        bridge_mode => BridgeMod,
        username => User,
        password => Password,
        clean_start => CleanStart,
        keepalive => KeepAlive,
        retry_interval => RetryIntv,
        max_inflight => MaxInflight,
        ssl => EnableSsl,
        ssl_opts => maps:to_list(maps:remove(enable, Ssl)),
        if_record_metrics => true
    }.

bridge_name(Prefix, Id) ->
    list_to_atom(str(Prefix) ++ ":" ++ str(Id)).

clientid(Id) ->
    list_to_binary(str(Id) ++ ":" ++ emqx_misc:gen_id(16)).

str(A) when is_atom(A) ->
    atom_to_list(A);
str(B) when is_binary(B) ->
    binary_to_list(B);
str(S) when is_list(S) ->
    S.
