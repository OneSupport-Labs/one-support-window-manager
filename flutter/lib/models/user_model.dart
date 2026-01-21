import 'dart:async';
import 'dart:convert';

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:get/get.dart';

import '../common.dart';
import '../utils/http_service.dart' as http;
import 'model.dart';
import 'platform_model.dart';

bool refreshingUser = false;

class UserModel {
  final RxString userName = ''.obs;
  final RxString userNameC = ''.obs;
  final RxBool isAdmin = false.obs;
  final RxString networkError = ''.obs;
  final RxBool _isLoginRx = false.obs;
  bool get isLogin => _isLoginRx.value;
  WeakReference<FFI> parent;

  UserModel(this.parent) {
    userName.listen((p0) {
      // When user name becomes empty, show login button
      // When user name becomes non-empty:
      //  For _updateLocalUserInfo, network error will be set later
      //  For login success, should clear network error
      networkError.value = '';
    });
    _isLoginRx.value =
        bind.mainGetLocalOption(key: 'access_token_c').isNotEmpty;
    userNameC.value = bind.mainGetLocalOption(key: 'user_name_c');
  }

  void refreshCurrentUser() async {
    if (bind.isDisableAccount()) return;
    networkError.value = '';
    final token = bind.mainGetLocalOption(key: 'access_token');
    if (token == '') {
      await updateOtherModels();
      return;
    }
    _updateLocalUserInfo();
    final url = await bind.mainGetApiServer();
    final body = {
      'id': await bind.mainGetMyId(),
      'uuid': await bind.mainGetUuid()
    };
    if (refreshingUser) return;
    try {
      refreshingUser = true;
      final http.Response response;
      try {
        response = await http.post(Uri.parse('$url/api/currentUser'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token'
            },
            body: json.encode(body));
      } catch (e) {
        networkError.value = e.toString();
        rethrow;
      }
      refreshingUser = false;
      final status = response.statusCode;
      if (status == 401 || status == 400) {
        reset(resetOther: status == 401);
        return;
      }
      final data = json.decode(decode_http_response(response));
      final error = data['error'];
      if (error != null) {
        throw error;
      }

      final user = UserPayload.fromJson(data);
      _parseAndUpdateUser(user);
    } catch (e) {
      debugPrint('Failed to refreshCurrentUser: $e');
    } finally {
      refreshingUser = false;
      await updateOtherModels();
    }
  }

  static Map<String, dynamic>? getLocalUserInfo() {
    final userInfo = bind.mainGetLocalOption(key: 'user_info');
    if (userInfo == '') {
      return null;
    }
    try {
      return json.decode(userInfo);
    } catch (e) {
      debugPrint('Failed to get local user info "$userInfo": $e');
    }
    return null;
  }

  _updateLocalUserInfo() {
    final userInfo = getLocalUserInfo();
    if (userInfo != null) {
      userName.value = userInfo['name'];
    }
    userNameC.value = bind.mainGetLocalOption(key: 'user_name_c');
    _isLoginRx.value =
        bind.mainGetLocalOption(key: 'access_token_c').isNotEmpty;
  }

  Future<void> reset({bool resetOther = false, bool resetAuto = true}) async {
    if (!resetAuto) {
      userNameC.value = '';
      await bind.mainSetLocalOption(key: 'user_name_c', value: '');
      await bind.mainSetLocalOption(key: 'access_token_c', value: '');
      await bind.mainSetLocalOption(key: 'refresh_token_c', value: '');
      _isLoginRx.value = false;
    }
    await bind.mainSetLocalOption(key: 'access_token', value: '');
    await bind.mainSetLocalOption(key: 'user_info', value: '');
    if (resetOther) {
      await gFFI.abModel.reset();
      await gFFI.groupModel.reset();
    }
    userName.value = '';
  }

  _parseAndUpdateUser(UserPayload user) {
    userName.value = user.name;
    isAdmin.value = user.isAdmin;
    bind.mainSetLocalOption(key: 'user_info', value: jsonEncode(user));
    if (isWeb) {
      // ugly here, tmp solution
      bind.mainSetLocalOption(key: 'verifier', value: user.verifier ?? '');
    }
  }

  // update ab and group status
  static Future<void> updateOtherModels() async {
    await Future.wait([
      gFFI.abModel.pullAb(force: ForcePullAb.listAndCurrent, quiet: false),
      gFFI.groupModel.pull()
    ]);
  }

  Future<void> logOut({String? apiServer, bool resetAuto = true}) async {
    final tag = gFFI.dialogManager.showLoading(translate('Waiting'));
    try {
      final url = apiServer ?? await bind.mainGetApiServer();
      final authHeaders = getHttpHeaders();
      authHeaders['Content-Type'] = "application/json";
      await http
          .post(Uri.parse('$url/api/logout'),
              body: jsonEncode({
                'id': await bind.mainGetMyId(),
                'uuid': await bind.mainGetUuid(),
              }),
              headers: authHeaders)
          .timeout(Duration(seconds: 2));
    } catch (e) {
      debugPrint("request /api/logout failed: err=$e");
    } finally {
      await reset(resetOther: true, resetAuto: resetAuto);
      gFFI.dialogManager.dismissByTag(tag);
    }
  }

  /// throw [RequestException]
  Future<LoginResponse> login(LoginRequest loginRequest) async {
    // Use custom API endpoint instead of the default RustDesk API
    const customApiUrl = 'https://1support.co.kr/api/auth/login/device';

    // Use MAC address as deviceId
    final deviceId = await bind.mainGetMac();
    final requestBody = {
      'username': loginRequest.username,
      'password': loginRequest.password,
      'deviceId': deviceId,
    };
    await bind.mainSetLocalOption(key: 'device_id_c', value: deviceId);

    final resp = await http.post(Uri.parse(customApiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody));

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(decode_http_response(resp));
    } catch (e) {
      debugPrint("login: jsonDecode resp body failed: ${e.toString()}");
      if (resp.statusCode != 200) {
        BotToast.showText(
            contentColor: Colors.red, text: 'HTTP ${resp.statusCode}');
      }
      rethrow;
    }
    if (resp.statusCode != 200) {
      throw RequestException(resp.statusCode, body['error'] ?? '');
    }
    if (body['error'] != null) {
      throw RequestException(0, body['error']);
    }

    // Transform custom API response to RustDesk LoginResponse format
    final transformedBody = {
      'type': HttpType.kAuthResTypeToken,
      'access_token': body['accessToken'],
      'user': {
        'name': requestBody['username'], // Use the username from request
      },
    };
    // Keep original body for extracting custom fields later
    transformedBody.addAll(body);

    return getLoginResponseFromAuthBody(transformedBody);
  }

  Future<LoginResponse> getLoginResponseFromAuthBody(
      Map<String, dynamic> body) async {
    final LoginResponse loginResponse;
    try {
      loginResponse = LoginResponse.fromJson(body);
    } catch (e) {
      debugPrint("login: jsonDecode LoginResponse failed: ${e.toString()}");
      rethrow;
    }

    final isLogInDone = loginResponse.type == HttpType.kAuthResTypeToken &&
        loginResponse.access_token != null;
        
    final oldApiServer = await bind.mainGetApiServer();

    if (isLogInDone && loginResponse.user != null) {
      _parseAndUpdateUser(loginResponse.user!);

      // Store accessToken if present in the response (from custom API)
      if (body.containsKey('accessToken') && body['accessToken'] != null) {
        await bind.mainSetLocalOption(
            key: 'access_token_c', value: body['accessToken'].toString());
        _isLoginRx.value = true;
        // Verify storage
        final verifyToken = bind.mainGetLocalOption(key: 'access_token_c');
        debugPrint('Stored accessToken. Verification read: $verifyToken');

        // Show dialog to user about token status
        if (verifyToken.isEmpty) {
          BotToast.showText(
              contentColor: Colors.red,
              text: 'WARNING: Token not saved! Please contact support.',
              duration: Duration(seconds: 5));
        } else {
          // Store user.name as userNameC
          if (body.containsKey('user') &&
              body['user'] != null &&
              body['user']['name'] != null) {
            final name = body['user']['name'].toString();
            userNameC.value = name;
            await bind.mainSetLocalOption(key: 'user_name_c', value: name);
          }
          BotToast.showText(
              contentColor: Colors.green,
              text: 'Login successful. Token saved.',
              duration: Duration(seconds: 2));
        }
      }

      // Store refreshToken if present in the response
      if (body.containsKey('refreshToken') && body['refreshToken'] != null) {
        await bind.mainSetLocalOption(
            key: 'refresh_token_c', value: body['refreshToken'].toString());
        debugPrint('Stored refreshToken');
      }



      // Store idServerIp and idServerKey if present in the response
      if (body.containsKey('idServerIp') &&
          body['idServerIp'] != null &&
          body.containsKey('idServerKey') &&
          body['idServerKey'] != null) {
        final idServer = body['idServerIp'].toString();
        final key = body['idServerKey'].toString();
        final serverConfig = ServerConfig()
          ..idServer = idServer
          ..relayServer = idServer
          ..apiServer = '' // Assuming no separate API server config for now
          ..key = key;

        await setServerConfig(null, null, serverConfig);
        debugPrint(
            'Applied server config using setServerConfig: ID/Relay=$idServer, Key=$key');
      }
    }

    logOut(apiServer: oldApiServer);
    return loginResponse;
  }

  static Future<List<dynamic>> queryOidcLoginOptions() async {
    try {
      final url = await bind.mainGetApiServer();
      if (url.trim().isEmpty) return [];
      final resp = await http.get(Uri.parse('$url/api/login-options'));
      final List<String> ops = [];
      for (final item in jsonDecode(resp.body)) {
        ops.add(item as String);
      }
      for (final item in ops) {
        if (item.startsWith('common-oidc/')) {
          return jsonDecode(item.substring('common-oidc/'.length));
        }
      }
      return ops
          .where((item) => item.startsWith('oidc/'))
          .map((item) => {'name': item.substring('oidc/'.length)})
          .toList();
    } catch (e) {
      debugPrint(
          "queryOidcLoginOptions: jsonDecode resp body failed: ${e.toString()}");
      return [];
    }
  }
}
