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

-record(mqtt_admin, {
    username             :: binary(),
    password             :: binary(),
    tags                 :: list() | binary(),
    role = undefined     :: atom()
    }).

-record(mqtt_admin_jwt, {
    token               :: binary(),
    username            :: binary(),
    exptime             :: integer()
    }).

-type(mqtt_admin() :: #mqtt_admin{}).

-define(EMPTY_KEY(Key), ((Key == undefined) orelse (Key == <<>>))).

-define(DASHBOARD_SHARD, emqx_dashboard_shard).

-record(mqtt_collect, {
    timestamp :: integer(),
    collect
    }).
