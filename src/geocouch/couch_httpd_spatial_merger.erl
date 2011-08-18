% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_httpd_spatial_merger).

-export([handle_req/1]).

-include("couch_db.hrl").
-include("couch_merger.hrl").
%-include("couch_spatial_merger.hrl").
-include("../ibrowse/ibrowse.hrl").

-import(couch_util, [
    get_value/2,
    get_value/3,
    to_binary/1
]).
-import(couch_httpd, [
    qs_json_value/3
]).


handle_req(#httpd{method = 'GET'} = Req) ->
    Indexes = validate_spatial_param(qs_json_value(Req, "spatial", nil)),
    MergeParams0 = #index_merge{
        indexes = Indexes
    },
    MergeParams1 = couch_httpd_view_merger:apply_http_config(Req, [], MergeParams0),
    couch_merger:query_index(couch_spatial_merger, Req, MergeParams1);

handle_req(#httpd{method = 'POST'} = Req) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    {Props} = couch_httpd:json_body_obj(Req),
    Indexes = validate_spatial_param(get_value(<<"spatial">>, Props)),
    MergeParams0 = #index_merge{
        indexes = Indexes
    },
    MergeParams1 = couch_httpd_view_merger:apply_http_config(Req, Props, MergeParams0),
    couch_merger:query_index(couch_spatial_merger, Req, MergeParams1);

handle_req(Req) ->
    couch_httpd:send_method_not_allowed(Req, "GET,POST").

%% Valid `spatial` example:
%%
%% {
%%   "spatial": {
%%     "localdb1": ["ddocname/spatialname", ...],
%%     "http://server2/dbname": ["ddoc/spatial"],
%%     "http://server2/_spatial_merge": {
%%       "spatial": {
%%         "localdb3": "spatialname", // local to server2
%%         "localdb4": "spatialname"  // local to server2
%%       }
%%     }
%%   }
%% }

validate_spatial_param({[_ | _] = Indexes}) ->
    lists:flatten(lists:map(
        fun({DbName, SpatialName}) when is_binary(SpatialName) ->
            {DDocDbName, DDocId, Vn} = parse_spatial_name(SpatialName),
            #simple_view_spec{
                database = DbName, ddoc_id = DDocId, view_name = Vn,
                ddoc_database = DDocDbName
            };
        ({DbName, SpatialNames}) when is_list(SpatialNames) ->
            lists:map(
                fun(SpatialName) ->
                    {DDocDbName, DDocId, Vn} = parse_spatial_name(SpatialName),
                    #simple_view_spec{
                        database = DbName, ddoc_id = DDocId, view_name = Vn,
                        ddoc_database = DDocDbName
                    }
                end, SpatialNames);
        ({MergeUrl, {[_ | _] = Props} = EJson}) ->
            case (catch ibrowse_lib:parse_url(?b2l(MergeUrl))) of
            #url{} ->
                ok;
            _ ->
                throw({bad_request, "Invalid spatial merge definition object."})
            end,
            case get_value(<<"spatial">>, Props) of
            {[_ | _]} = SubSpatial ->
                SubSpatialSpecs = validate_spatial_param(SubSpatial),
                case lists:any(
                    fun(#simple_view_spec{}) -> true; (_) -> false end,
                    SubSpatialSpecs) of
                true ->
                    ok;
                false ->
                    SubMergeError = io_lib:format("Could not find a"
                        " non-composed spatial spec in the spatial merge"
                        " targeted at `~s`",
                        [rem_passwd(MergeUrl)]),
                    throw({bad_request, SubMergeError})
                end,
                #merged_view_spec{url = MergeUrl, ejson_spec = EJson};
            _ ->
                SubMergeError = io_lib:format("Invalid spatial merge"
                    " definition for sub-merge done at `~s`.",
                    [rem_passwd(MergeUrl)]),
                throw({bad_request, SubMergeError})
            end;
        (_) ->
            throw({bad_request, "Invalid spatial merge definition object."})
        end, Indexes));

validate_spatial_param(_) ->
    throw({bad_request, <<"`spatial` parameter must be an object with at ",
                          "least 1 property.">>}).

parse_spatial_name(Name) ->
    case string:tokens(couch_util:trim(?b2l(Name)), "/") of
    [DDocName, ViewName0] ->
        {nil, <<"_design/", (?l2b(DDocName))/binary>>, ?l2b(ViewName0)};
    ["_design", DDocName, ViewName0] ->
        {nil, <<"_design/", (?l2b(DDocName))/binary>>, ?l2b(ViewName0)};
    [DDocDbName1, DDocName, ViewName0] ->
        DDocDbName = ?l2b(couch_httpd:unquote(DDocDbName1)),
        {DDocDbName, <<"_design/", (?l2b(DDocName))/binary>>, ?l2b(ViewName0)};
    [DDocDbName1, "_design", DDocName, ViewName0] ->
        DDocDbName = ?l2b(couch_httpd:unquote(DDocDbName1)),
        {DDocDbName, <<"_design/", (?l2b(DDocName))/binary>>, ?l2b(ViewName0)};
    _ ->
        throw({bad_request, "A `spatial` property must have the shape"
            " `ddoc_name/spatial_name`."})
    end.

rem_passwd(Url) ->
    ?l2b(couch_util:url_strip_password(Url)).
