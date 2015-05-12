%% Copyright (c) 2012-2015 Basho Technologies, Inc.
%% This repl hook skips some objects in Riak CS

%% @doc Handle filters on replicating Riak CS specific data. See also
%% test/riak_repl_cs_eqc.erl to know which is replicated or not, in
%% fullsync or realtime.
%%
%% For blocks, all tombstones are replicated by default, which is
%% exception for tombstones. This is to reclaim data space faster.  CS
%% wants to delete blocks as fast as possible, because keys of blocks
%% consumes memory space, disk space and disk IO. Deletion conflict in
%% cross-replicated configuration won't be any problem because they
%% are just deletion.
%%
%% You should not replicate blocks neither in fullsync or realtime as
%% there are a race condition related to CS garbage collection.

-module(riak_repl_cs).

-ifdef(TEST).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([send_realtime/2, send/2, recv/1]).

-define(BLOCK_BUCKET_PREFIX, "0b:").
-define(USER_BUCKET, <<"moss.users">>).
-define(ACCESS_BUCKET, <<"moss.access">>).
-define(STORAGE_BUCKET, <<"moss.storage">>).
-define(BUCKETS_BUCKET, <<"moss.buckets">>).

-define(CONFIG_REPL_BLOCKS, replicate_cs_blocks_realtime).
-define(CONFIG_REPL_BLOCK_TOMBSTONE, replicate_cs_block_tombstone).
-define(CONFIG_REPL_USERS, replicate_cs_user_objects).
-define(CONFIG_REPL_BUCKETS, replicate_cs_bucket_objects).

%% For fullsync, we don't want to ever replicate tombstones or blocks
%% or storage or access.  Depending on app.config, we may or may not
%% want to replicate user and bucket objects. An exception is
%% tombstones of blocks.
-spec send(riak_object:riak_object(), riak_client:riak_client()) ->
    ok | cancel.
send(Object, _RiakClient) ->
    bool_to_ok_or_cancel(replicate_object(
                           riak_object:bucket(Object),
                           riak_kv_util:is_x_deleted(Object),
                           fullsync)).

-spec recv(riak_object:riak_object()) -> ok | cancel.
recv(_Object) ->
    ok.

%% For realtime, we don't want to ever replicate tombstones or storage
%% or access. Depending on app.config, we may or may not want to
%% replicate user and bucket objects. An exception is tombstones of
%% blocks.
-spec send_realtime(riak_object:riak_object(), riak_client:riak_client()) ->
    ok | cancel.
send_realtime(Object, _RiakClient) ->
    bool_to_ok_or_cancel(replicate_object(
                           riak_object:bucket(Object),
                           riak_kv_util:is_x_deleted(Object),
                           realtime)).

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec replicate_object(binary(), boolean(), fullsync|realtime) -> boolean().
replicate_object(<<?BLOCK_BUCKET_PREFIX, _Rest/binary>>, IsTombstone, FSorRT) ->
    case {IsTombstone, FSorRT} of
        {false, fullsync} ->
            true;
        {false, realtime} ->
            app_helper:get_env(riak_repl, ?CONFIG_REPL_BLOCKS, false);
        {true, _} ->
            app_helper:get_env(riak_repl, ?CONFIG_REPL_BLOCK_TOMBSTONE, true)
    end;
replicate_object(_, true, _) -> false;
replicate_object(?STORAGE_BUCKET, _, _) -> false;
replicate_object(?ACCESS_BUCKET, _, _) -> false;
replicate_object(?USER_BUCKET, _, _) ->
    app_helper:get_env(riak_repl, ?CONFIG_REPL_USERS, true);
replicate_object(?BUCKETS_BUCKET, _, _) ->
    app_helper:get_env(riak_repl, ?CONFIG_REPL_BUCKETS, true);
replicate_object(_, _, _) -> true.


-spec bool_to_ok_or_cancel(boolean()) -> ok | cancel.
bool_to_ok_or_cancel(true) ->
    ok;
bool_to_ok_or_cancel(false) ->
    cancel.

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

reset_app_env() ->
    ok = application:unset_env(riak_repl, ?CONFIG_REPL_BLOCKS),
    ok = application:unset_env(riak_repl, ?CONFIG_REPL_BLOCK_TOMBSTONE),
    ok = application:unset_env(riak_repl, ?CONFIG_REPL_USERS),
    ok = application:unset_env(riak_repl, ?CONFIG_REPL_BLOCKS).

repl_blocks_test() ->
    reset_app_env(),
    %% the riak client isn't even used
    Client = fake_client,
    Bucket = <<"0b:foo">>,
    Object = riak_object:new(Bucket, <<"key">>, <<"val">>),
    ?assert(ok_or_cancel_to_bool(send(Object, Client))),
    ?assertNot(ok_or_cancel_to_bool(send_realtime(Object, Client))).

dont_repl_access_objects_test() ->
    reset_app_env(),
    %% the riak client isn't even used
    Client = fake_client,
    Bucket = <<"moss.access">>,
    Object = riak_object:new(Bucket, <<"key">>, <<"val">>),
    ?assertNot(ok_or_cancel_to_bool(send(Object, Client))),
    ?assertNot(ok_or_cancel_to_bool(send_realtime(Object, Client))).

dont_repl_storage_objects_test() ->
    reset_app_env(),
    %% the riak client isn't even used
    Client = fake_client,
    Bucket = <<"moss.storage">>,
    Object = riak_object:new(Bucket, <<"key">>, <<"val">>),
    ?assertNot(ok_or_cancel_to_bool(send(Object, Client))),
    ?assertNot(ok_or_cancel_to_bool(send_realtime(Object, Client))).

dont_repl_tombstoned_object_test() ->
    reset_app_env(),
    ok = application:set_env(riak_repl, replicate_block_tombstone, false),
    %% the riak client isn't even used
    Client = fake_client,
    Bucket = <<"anything">>,
    Object = riak_object:new(Bucket, <<"key">>, <<"val">>),
    M = dict:from_list([{<<"X-Riak-Deleted">>, true}]),
    Object2 = riak_object:update_metadata(Object, M),
    Object3 = riak_object:apply_updates(Object2),
    ?assertNot(ok_or_cancel_to_bool(send(Object3, Client))),
    ?assertNot(ok_or_cancel_to_bool(send_realtime(Object3, Client))).

repl_user_object_test() ->
    reset_app_env(),
    %% the riak client isn't even used
    Client = fake_client,
    Bucket = <<"moss.users">>,
    Object = riak_object:new(Bucket, <<"key">>, <<"val">>),
    application:set_env(riak_repl, replicate_cs_user_objects, true),
    ?assert(ok_or_cancel_to_bool(send(Object, Client))),
    ?assert(ok_or_cancel_to_bool(send_realtime(Object, Client))),
    application:set_env(riak_repl, replicate_cs_user_objects, false),
    ?assertNot(ok_or_cancel_to_bool(send(Object, Client))),
    ?assertNot(ok_or_cancel_to_bool(send_realtime(Object, Client))).

repl_bucket_object_test() ->
    reset_app_env(),
    %% the riak client isn't even used
    Client = fake_client,
    Bucket = <<"moss.buckets">>,
    Object = riak_object:new(Bucket, <<"key">>, <<"val">>),
    application:set_env(riak_repl, replicate_cs_bucket_objects, true),
    ?assert(ok_or_cancel_to_bool(send(Object, Client))),
    ?assert(ok_or_cancel_to_bool(send_realtime(Object, Client))),
    application:set_env(riak_repl, replicate_cs_bucket_objects, false),
    ?assertNot(ok_or_cancel_to_bool(send(Object, Client))),
    ?assertNot(ok_or_cancel_to_bool(send_realtime(Object, Client))).


do_repl_gc_object_test() ->
    reset_app_env(),
    Client = fake_client,
    Bucket = <<"riak-cs-gc">>,
    Object = riak_object:new(Bucket, <<"key">>, <<"val">>),
    ?assert(ok_or_cancel_to_bool(send_realtime(Object, Client))),
    ?assert(ok_or_cancel_to_bool(send(Object, Client))).

do_repl_mb_weight_test() ->
    reset_app_env(),
    Client = fake_client,
    Bucket = <<"riak-cs-multibag">>,
    Object = riak_object:new(Bucket, <<"key">>, <<"val">>),
    ?assert(ok_or_cancel_to_bool(send_realtime(Object, Client))),
    ?assert(ok_or_cancel_to_bool(send(Object, Client))).


%% ===================================================================
%% EUnit helpers
%% ===================================================================

ok_or_cancel_to_bool(ok) ->
    true;
ok_or_cancel_to_bool(cancel) ->
    false.

-endif.
