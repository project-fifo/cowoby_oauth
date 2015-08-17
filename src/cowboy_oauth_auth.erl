-module(cowboy_oauth_auth).

-include("cowboy_oauth.hrl").

-export([init/3]).
-export([handle/2]).
-export([terminate/3]).

-ignore_xref([init/3]).
-ignore_xref([handle/2]).
-ignore_xref([terminate/3]).


-record(auth_req, {
          response_type,
          client_id,
          redirect_uri,
          scope,
          username,
          password,
          state,
          method,
          user_uuid,
          urls,
          bearer
         }).

init(_Transport, Req, []) ->
	{ok, Req, <<"/">>};
init(_Transport, Req, [TokenURL, MFAURL]) ->
	{ok, Req, {TokenURL, MFAURL}}.

terminate(_Reason, _Req, _State) ->
	ok.

handle(Req, URLs) ->
    {ok, Req3} = case cowboy_req:method(Req) of
                     %% TODO: This should prompt a permission form
                     %% And check for the bearer token
                     {<<"GET">>, Req2} ->
                         do_get(Req2, URLs);
                     %% TODO: This should do the actual redirect etc.
                     {<<"POST">>, Req2} ->
                         do_post(Req2, URLs);
                     {_, Req2} ->
                         cowboy_req:reply(405, Req2)
                 end,
    lager:info("[oath:auth] Request finished!"),
    {ok, Req3, URLs}.

do_get(Req, URLs) ->
    {QSVals, Req2} = cowboy_req:qs_vals(Req),
    AuthReq = #auth_req{method = get, urls = URLs},
    do_vals(AuthReq, QSVals, Req2).

do_post(Req, URLs)->
    {ok, PostVals, Req2} = cowboy_req:body_qs(Req),
    AuthReq = #auth_req{method = post, urls = URLs},
    do_vals(AuthReq, PostVals, Req2).

do_vals(AuthReq, Vals, Req) ->
    ResponseType = cowboy_oauth:decode_response_type(
                     proplists:get_value(<<"response_type">>, Vals)),
    ClientID = proplists:get_value(<<"client_id">>, Vals),
    RedirectURI = proplists:get_value(<<"redirect_uri">>, Vals),
    Scope = proplists:get_value(<<"scope">>, Vals),
    State = proplists:get_value(<<"state">>, Vals),
    Username = proplists:get_value(<<"username">>, Vals),
    Password = proplists:get_value(<<"password">>, Vals),
    AuthReq1 = AuthReq#auth_req{
                 response_type = ResponseType,
                 client_id = ClientID,
                 redirect_uri = RedirectURI,
                 username = Username,
                 password = Password,
                 scope = Scope,
                 state = State},
    do_basic_auth(AuthReq1, Req).

do_basic_auth(AuthReq, Req) ->
    {ok, Auth, Req1} = cowboy_req:parse_header(<<"authorization">>, Req),
    case Auth of
        {<<"basic">>, {Username, Password}} ->
            AuthReq1 = AuthReq#auth_req{username = Username, password = Password},
            update_scope(AuthReq1, Req1);
        {<<"bearer">>, Bearer} ->
            AuthReq1 = AuthReq#auth_req{bearer = Bearer},
            check_token(AuthReq1, Req1);
        _ ->
            update_scope(AuthReq, Req1)
    end.

check_token(AuthReq = #auth_req{bearer = Bearer}, Req) ->
    case ls_oauth:verify_access_token(Bearer) of
        {ok, Context} ->
            case proplists:get_value(<<"resource_owner">>, Context) of
                undefined ->
                    cowboy_oauth:json_error_response(access_denied, Req);
                OwnerUUID ->
                    AuthReq1 = AuthReq#auth_req{user_uuid = OwnerUUID},
                    update_scope(AuthReq1, Req)
          end;
        _ ->
            cowboy_oauth:json_error_response(access_denied, Req)
    end.

update_scope(AuthReq = #auth_req{scope = Scope}, Req) ->
    do_request(AuthReq#auth_req{
                 scope = cowboy_oauth:list_to_scope(Scope)
                }, Req).

do_request(AuthReq = #auth_req{method = get}, Req) ->
    Params = build_params(AuthReq),
    Form = application:get_env(cowboy_oauth, oauth_form, oauth_login_form_dtl),
    {ok, Reply}  = Form:render(Params),
    cowboy_req:reply(200, [], Reply, Req);

do_request(AuthReq = #auth_req{response_type = code}, Req) ->
    do_code(AuthReq, Req);

do_request(AuthReq = #auth_req{response_type = token}, Req) ->
    do_token(AuthReq, Req);

do_request(#auth_req{}, Req) ->
    cowboy_oauth:json_error_response(unsupported_response_type, Req).


%% 4.1.1
do_code(#auth_req{
           client_id = ClientID,
           redirect_uri = URI,
           user_uuid = UserUUID,
           scope = Scope,
           state = State,
           urls = URLs}, Req)
  when is_binary(UserUUID),
       is_binary(ClientID) ->
    do_code({UserUUID}, ClientID, URI, Scope, State, URLs, Req);

do_code(#auth_req{
           client_id = ClientID,
           redirect_uri = URI,
           username = Username,
           password = Password,
           scope = Scope,
           state = State,
           urls = URLs}, Req)
  when is_binary(Username),
       is_binary(Password),
       is_binary(ClientID) ->
    do_code({Username, Password}, ClientID, URI, Scope, State, URLs, Req);

do_code(#auth_req{redirect_uri = Uri, state = State}, Req) ->
    cowboy_oauth:redirected_error_response(Uri, invalid_request, State, Req).

do_code(User, ClientID, URI, Scope, State, {_, MFAUrl}, Req) ->
    case ls_oauth:authorize_code_request(User, ClientID, URI, Scope) of
        {ok, Authorization = #a{resowner = UUID}} ->
            case ls_user:yubikeys(UUID) of
                {ok, []} ->
                    {ok, Response} = ls_oauth:issue_code(Authorization),
                    {ok, Code} = oauth2_response:access_code(Response),
                    cowboy_oauth:redirected_authorization_code_response(URI, Code, State, Req);
                {ok, _} ->
                    %%TODO
                    cowboy_oauth:redirected_2fa_request(
                      <<"code">>, UUID, Authorization, State, URI, MFAUrl,
                      Req)
            end;
        {error, unauthorized_client} ->
            %% cliend_id is not registered or redirection_uri is not valid
            cowboy_oauth:json_error_response(unauthorized_client, Req);
        {error, Error} ->
            cowboy_oauth:redirected_error_response(URI, Error, State, Req)
    end.

do_token(#auth_req{
            client_id = ClientID,
            redirect_uri = URI,
            user_uuid = UserUUID,
            scope = Scope,
            state = State,
            urls = URLs}, Req)
  when is_binary(UserUUID),
       is_binary(ClientID) ->
    do_token({UserUUID}, ClientID, URI, Scope, State, URLs, Req);

do_token(#auth_req{
            client_id = ClientID,
            redirect_uri = URI,
            username = Username,
            password = Password,
            scope = Scope,
            state = State,
            urls = URLs}, Req)
  when is_binary(Username),
       is_binary(Password),
       is_binary(ClientID) ->
    do_token({Username, Password}, ClientID, URI, Scope, State, URLs, Req);

do_token(#auth_req{redirect_uri = Uri, state = State}, Req) ->
    cowboy_oauth:redirected_error_response(Uri, invalid_request, State, Req).


do_token(Authentication, ClientID, URI, Scope, State, URLs, Req) when
      is_binary(ClientID) ->
    {ok, C} = ls_client:lookup(ClientID),
    UUID = ft_client:uuid(C),
    do_token(Authentication, {UUID}, URI, Scope, State, URLs, Req);

do_token(Authentication, ClientID, URI, Scope, State, {_, MFAUrl}, Req) when
      is_tuple(Authentication),
      is_tuple(ClientID) ->
    case ls_oauth:authorize_password(Authentication, ClientID, URI, Scope) of
        {ok, Authorization = #a{resowner = UUID}} ->
            case ls_user:yubikeys(UUID) of
                {ok, []} ->

                    {ok, Response} = ls_oauth:issue_token(Authorization),
                    {ok, AccessToken} = oauth2_response:access_token(Response),
                    {ok, Type} = oauth2_response:token_type(Response),
                    {ok, Expires} = oauth2_response:expires_in(Response),
                    {ok, VerifiedScope} = oauth2_response:scope(Response),
                    cowboy_oauth:redirected_access_token_response(URI,
                                                                  AccessToken,
                                                                  Type,
                                                                  Expires,
                                                                  VerifiedScope,
                                                                  State,
                                                                  Req);
                {ok, _} ->
                    cowboy_oauth:redirected_2fa_request(
                      <<"token">>, UUID, Authorization, State, URI, MFAUrl, Req)
            end;
        {error, Error} ->
            cowboy_oauth:redirected_error_response(URI, Error, State, Req)
    end.

build_params(R = #auth_req{response_type = code, urls = {FormURL, _}}) ->
    build_params(R, [{response_type, <<"code">>}, {form_target, FormURL}]);

build_params(R = #auth_req{response_type = token, urls = {FormURL, _}}) ->
    build_params(R, [{response_type, <<"token">>}, {form_target, FormURL}]);
build_params(_) ->
    [{error, <<"illegal request type">>}].


build_params(R = #auth_req{client_id = ClientID}, Acc)
  when ClientID =/= undefined ->
    {ok, Client} = ls_client:lookup(ClientID),
    build_params1(R, [{client_id, ClientID},
                      {client_name, ft_client:name(Client)} | Acc]);
build_params(_, _) ->
    [{error, <<"no_client_id">>}].

build_params1(R = #auth_req{redirect_uri = RedirectURI}, Acc)
  when RedirectURI =/= undefined ->
    build_params2(R, [{redirect_uri, RedirectURI} | Acc]);
build_params1(R, Acc) ->
    build_params2(R, Acc).


build_params2(R = #auth_req{scope = Scope}, Acc)
  when Scope =/= undefined ->
    Descs = scope_desc(Scope),
    build_params3(R, [{scope, cowboy_oauth:scope_to_list(Scope)},
                      {scope_list, Descs} | Acc]);

build_params2(R, Acc) ->
    build_params3(R, Acc).

build_params3(R = #auth_req{user_uuid = OwnerUUID}, Acc)
  when OwnerUUID =/= undefined ->
    {ok, User} = ls_user:get(OwnerUUID),
    build_params4(R, [{user_name, ft_user:name(User)} | Acc]);

build_params3(R, Acc) ->
    build_params4(R, Acc).

build_params4(#auth_req{state = State}, Acc)
  when State =/= undefined ->
    [{state, State} | Acc];
build_params4(_R, Acc) ->
    Acc.

scope_desc(Scope) ->
    [Desc || {_, Desc, _, _} <- ls_oauth:scope(Scope)].
