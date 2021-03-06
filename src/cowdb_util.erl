%%-*- mode: erlang -*-
%%
%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
-module(cowdb_util).

-include("cowdb.hrl").


-define(DEFAULT_COMPACT_LIMIT, 2048000).


-export([set_property/3,
         delete_property/2,
         apply/2,
         timestamp/0,
         get_value/2, get_value/3,
         get_opt/2, get_opt/3,
         reorder_results/2,
         uniqid/0,
         init_db/6,
         maybe_sync/3,
         write_header/2,
         commit_transaction/2,
         shutdown_sync/1,
         delete_file/1, delete_file/2]).

set_property(Key, Value, Props) ->
    case lists:keyfind(Key, 1, Props) of
        false -> [{Key, Value} | Props];
        _ -> lists:keyreplace(Key, 1, Props, {Key, Value})
    end.

delete_property(Key, Props) ->
    case lists:keyfind(Key, 1, Props) of
        false -> Props;
        _ -> lists:keydelete(Key, 1, Props)
    end.

apply(Func, Args) ->
    case Func of
        {M, F, A} ->
            Args1 = Args ++ A,
            erlang:apply(M, F, Args1);
        {M, F} ->
            erlang:apply(M, F, Args);
        F ->
            erlang:apply(F, Args)
    end.

timestamp() ->
    {A, B, _} = os:timestamp(),
    (A * 1000000) + B.

get_value(Key, List) ->
    get_value(Key, List, undefined).

get_value(Key, List, Default) ->
    case lists:keysearch(Key, 1, List) of
    {value, {Key,Value}} ->
        Value;
    false ->
        Default
    end.

get_opt(Key, Opts) ->
    get_opt(Key, Opts, undefined).

get_opt(Key, Opts, Default) ->
    case proplists:get_value(Key, Opts) of
        undefined ->
            case application:get_env(?MODULE, Key) of
                {ok, Value} -> Value;
                undefined -> Default
            end;
        Value ->
            Value
    end.

% linear search is faster for small lists, length() is 0.5 ms for 100k list
reorder_results(Keys, SortedResults) when length(Keys) < 100 ->
    [get_value(Key, SortedResults) || Key <- Keys];
reorder_results(Keys, SortedResults) ->
    KeyDict = dict:from_list(SortedResults),
    [dict:fetch(Key, KeyDict) || Key <- Keys].

uniqid() ->
    integer_to_list(erlang:phash2(make_ref())).

%% @doc initialize the db
init_db(Header, DbPid, Fd, ReaderFd, FilePath, Options) ->
    DefaultFSyncOptions = [before_header, after_header, on_file_open],
    FSyncOptions = get_opt(fsync_options, Options, DefaultFSyncOptions),

    CompactLimit = get_opt(compact_limit, Options, ?DEFAULT_COMPACT_LIMIT),
    AutoCompact = get_opt(auto_compact, Options, false),

    %% maybe sync the header
    ok = maybe_sync(on_file_open, Fd, FSyncOptions),

    %% extract db info from the header
    #db_header{tid=Tid,
               by_id=IdP,
               log=LogP} = Header,


    %% initialize the btree
    Compression = get_opt(compression, Options, ?DEFAULT_COMPRESSION),
    DefaultLess = fun(A, B) -> A < B end,
    Less = get_opt(less, Options, DefaultLess),
    {UsrReduce, Reduce} = by_id_reduce(Options),

    {ok, IdBt} = cowdb_btree:open(IdP, Fd, [{compression, Compression},
                                          {less, Less},
                                          {reduce, Reduce}]),

    {ok, LogBt} = cowdb_btree:open(LogP, Fd, [{compression, Compression},
                                            {reduce, fun log_reduce/2}]),

    %% initial db record
    #db{tid=Tid,
        start_time=timestamp(),
        db_pid=DbPid,
        updater_pid=self(),
        fd=Fd,
        reader_fd=ReaderFd,
        by_id=IdBt,
        log=LogBt,
        header=Header,
        file_path=FilePath,
        fsync_options=FSyncOptions,
        auto_compact=AutoCompact,
        compact_limit=CompactLimit,
        reduce_fun=UsrReduce,
        options=Options}.

%% @doc test if the db file should be synchronized or not depending on the
%% state
maybe_sync(Status, Fd, FSyncOptions) ->
    case lists:member(Status, FSyncOptions) of
        true ->
            ok = cowdb_file:sync(Fd),
            ok;
        _ ->
            ok
    end.


%% @doc write the db header
write_header(Header, #db{fd=Fd, fsync_options=FsyncOptions}) ->
    ok = maybe_sync(before_header, Fd, FsyncOptions),
    {ok, _} = cowdb_file:write_header(Fd, Header),
    ok = maybe_sync(after_headerr, Fd, FsyncOptions),
    ok.


%% @doc commit the transaction on the disk.
commit_transaction(TransactId, #db{by_id=IdBt,
                                   log=LogBt,
                                   header=OldHeader}=Db) ->

    %% write the header
    NewHeader = OldHeader#db_header{tid=TransactId,
                                    by_id=cowdb_btree:get_state(IdBt),
                                    log=cowdb_btree:get_state(LogBt)},
    ok = cowdb_util:write_header(NewHeader, Db),
    {ok, Db#db{tid=TransactId, header=NewHeader}}.


%% @doc synchronous shutdown
shutdown_sync(Pid) when not is_pid(Pid)->
    ok;
shutdown_sync(Pid) ->
    MRef = erlang:monitor(process, Pid),
    try
        catch unlink(Pid),
        catch exit(Pid, shutdown),
        receive
        {'DOWN', MRef, _, _, _} ->
            receive
            {'EXIT', Pid, _} ->
                ok
            after 0 ->
                ok
            end
        end
    after
        erlang:demonitor(MRef, [flush])
    end.

%% @doc delete a file safely
delete_file(FilePath) ->
    delete_file(FilePath, false).

delete_file(FilePath, Async) ->
    DelFile = FilePath ++ uniqid(),
    case file:rename(FilePath, DelFile) of
    ok ->
        if (Async) ->
            spawn(file, delete, [DelFile]),
            ok;
        true ->
            file:delete(DelFile)
        end;
    Error ->
        Error
    end.

%% private functions
%%
by_id_reduce(Options) ->
    case lists:keyfind(reduce, 1, Options) of
        false ->
            {nil, fun (reduce, KVs) ->
                    Count = length(KVs),
                    Size = lists:sum([S || {_, {_, {_, S}, _, _}} <- KVs]),
                    {Count, Size};
                (rereduce, Reds) ->
                    Count = lists:sum([Count0 || {Count0, _} <- Reds]),
                    AccSize = lists:sum([Size || {_, Size} <- Reds]),
                    {Count, AccSize}
            end};
        {_, ReduceFun0} ->
            {ReduceFun0, fun(reduce, KVs) ->
                    Count = length(KVs),
                    Size = lists:sum([S || {_, {_, {_, S}, _, _}} <- KVs]),
                    Result = ReduceFun0(reduce, KVs),
                    {Count, Size, Result};
                (rereduce, Reds) ->
                    Count = lists:sum([Count0 || {Count0, _, _} <- Reds]),
                    AccSize = lists:sum([Size || {_, Size, _} <- Reds]),
                    UsrReds = [UsrRedsList || {_, UsrRedsList} <- Reds],
                    Result = ReduceFun0(rereduce, UsrReds),
                    {Count, AccSize, Result}
            end}
    end.


log_reduce(reduce, KVS) ->
    length(KVS);
log_reduce(rereduce, Reds) ->
    lists:sum(Reds).
