import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:url_launcher/url_launcher.dart';

class AuthService extends ChangeNotifier {
  // Instancia privada estática para el Singleton
  static final AuthService _instance = AuthService._internal();

  // Constructor privado para evitar instanciación fuera de esta clase
  AuthService._internal();

  // Método para obtener la instancia única de AuthService
  factory AuthService() {
    return _instance;
  }

  final FlutterSecureStorage _storage = FlutterSecureStorage();

  // Guardar token de acceso
  Future<void> saveTokens({required String accessToken, String? refreshToken}) async {
    await _storage.write(key: 'access_token', value: accessToken);
    if (refreshToken != null) {
      await _storage.write(key: 'refresh_token', value: refreshToken);
    }
  }

  // Leer token de acceso
  Future<String?> getToken() async {
    return await _storage.read(key: 'access_token');
  }
  // Leer refresh token
  Future<String?> getRefreshToken() async {
    return await _storage.read(key: 'refresh_token');
  }

  // Verificar si hay un token guardado y si es válido
  Future<bool> get isLoggedIn async {
    String? token = await getToken();
    // Para una verificación más robusta, podrías intentar validar el token aquí
    // o simplemente verificar su existencia. Si tienes un refresh token,
    // podrías considerar al usuario "potencialmente logueado".
    // Por ahora, nos basamos en la existencia del access token.
    return token != null && token.isNotEmpty;
  }

  // Método para cerrar sesión
  Future<void> logout() async {
    await _storage.delete(key: 'access_token');
    notifyListeners(); // Notifica cambios
  }

  // Método para reiniciar el flujo
  Future<void> logoutAndAllowAccountChange(BuildContext context) async {
    // Accedemos a la instancia singleton de GraphService para obtener los endpoints y redirectUri
    final graphServiceInstance = GraphService();
    final String postLogoutRedirectUri = graphServiceInstance.redirectUri;
    final String endSessionUrl = graphServiceInstance.endSessionEndpoint;

    final Uri logoutUri = Uri.parse(endSessionUrl).replace(
      queryParameters: {
        'post_logout_redirect_uri': postLogoutRedirectUri,
      },
    );

    // 1. Abrir logout en el navegador para borrar la sesión real
    if (await canLaunchUrl(logoutUri)) {
      await launchUrl(
        logoutUri,
        mode: LaunchMode.externalApplication, // IMPORTANTE: navegador externo
      );
    } else {
      print('Could not launch $logoutUri');
      // Considerar mostrar un mensaje al usuario si no se puede abrir la URL de logout
    }

    // 2. Borrar credenciales locales (se hace después de intentar el logout en el navegador)
    await _storage.delete(key: 'access_token');
    await _storage.delete(key: 'refresh_token');

    // 3. Notificar a los listeners
    notifyListeners();
  }
}

class GraphService {
  // Instancia privada estática para el Singleton
  static final GraphService _instance = GraphService._internal();

  late AuthService _authService;
  final FlutterAppAuth appAuth = FlutterAppAuth();

  // Constructor privado para evitar instanciación fuera de esta clase
  GraphService._internal();

  // Método para obtener la instancia única de AuthService
  factory GraphService() {
    return _instance;
  }

  // Método para inicializar AuthService (solo se llama una vez)
  void init(AuthService authService) {
    _authService = authService;
  }

  // Método para obtener el token desde AuthService
  Future<String?> getToken() async {
    return await _authService.getToken();
  }

  final String clientId = dotenv.env['CLIENT_ID'] ?? '';
  final String tenantId = dotenv.env['TENANT_ID'] ?? '';
  final List<String> scope = ['User.Read', "Files.ReadWrite.All", "Files.Read.All"];
  final String redirectUri = 'com.example.onedrivegallery://auth';
  final String authorizationEndpoint = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize';
  final String tokenEndpoint = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/token';
  final String endSessionEndpoint = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/logout';

  // Solicitar tokens iniciales
  Future<String?> requestToken({bool promptSelectAccount = false}) async {
    try {
      List<String>? promptValues;
      if (promptSelectAccount) {
        promptValues = ['select_account'];
      }

      final AuthorizationTokenResponse? result = await appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          clientId,
          redirectUri,
          serviceConfiguration: AuthorizationServiceConfiguration(authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint, endSessionEndpoint: endSessionEndpoint),
          scopes: scope,
          promptValues: promptValues,
        ),
      );
      if (result != null && result.accessToken != null) {
        await _authService.saveTokens(
          accessToken: result.accessToken!,
          refreshToken: result.refreshToken,
        );
        return result.accessToken;
      } else {
        print('Authentication result is null or missing access token');
        return null;
      }
    } catch (e) {
      print('Authentication error: $e');
      return null;
    }
  }

  // Refrescar el token de acceso usando el refresh token
  Future<String?> refreshAccessToken() async {
    print("Attempting to refresh access token...");
    try {
      final String? refreshToken = await _authService.getRefreshToken();
      if (refreshToken == null) {
        print('No refresh token available.');
        await _authService.logout(); // No hay refresh token, forzar logout
        return null;
      }

      final TokenResponse? result = await appAuth.token(
        TokenRequest(
          clientId,
          redirectUri,
          refreshToken: refreshToken,
          serviceConfiguration: AuthorizationServiceConfiguration(authorizationEndpoint: authorizationEndpoint, tokenEndpoint: tokenEndpoint, endSessionEndpoint: endSessionEndpoint),
          scopes: scope,
        ),
      );

      if (result != null && result.accessToken != null) {
        await _authService.saveTokens(
          accessToken: result.accessToken!,
          refreshToken: result.refreshToken ?? refreshToken, // Usar el nuevo refresh token si se proporciona, sino mantener el anterior
        );
        print("Access token refreshed successfully.");
        return result.accessToken;
      }
    } catch (e) {
      print('Error refreshing access token: $e');
      await _authService.logoutAndAllowAccountChange(GlobalKey<NavigatorState>().currentContext ?? (throw Exception("No context available for logout"))); // Falló el refresh, forzar logout y permitir cambio de cuenta
      return null;
    }
    print('Failed to refresh access token, result was null.');
    await _authService.logoutAndAllowAccountChange(GlobalKey<NavigatorState>().currentContext ?? (throw Exception("No context available for logout")));
    return null;
  }

  final String _baseUrl = "https://graph.microsoft.com/v1.0/me/drive/";

  // Obtener archivos desde OneDrive
  Future<List<dynamic>> getDriveFiles() async {
    final token = await getToken();
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };

    List<dynamic> files = [];

    try {
      // Solicitar archivos de la carpeta raíz
      final response = await http.get(Uri.parse('$_baseUrl/root/children'), headers: headers);

      if (response.statusCode == 200) {
        var data = jsonDecode(response.body);
        files = data['value']; // Archivos en la carpeta raíz

        // Obtener archivos compartidos
        final sharedResponse = await http.get(Uri.parse('$_baseUrl/sharedWithMe'), headers: headers);

        if (sharedResponse.statusCode == 200) {
          var sharedData = jsonDecode(sharedResponse.body);
          files.addAll(sharedData['value']); // Archivos compartidos
        }
      } else {
        print('Failed to load files');
      }
    } catch (e) {
      print('Error fetching files: $e');
    }

    return files;
  }

  // Wrapper para realizar solicitudes GET autenticadas con manejo de refresh token
  Future<http.Response> _makeAuthenticatedGetRequest(String url, {Map<String, String>? currentHeaders}) async {
    String? accessToken = await getToken();
    if (accessToken == null) {
      print('No access token found for request. User needs to login.');
      // Podrías forzar un logout aquí o lanzar una excepción más específica
      // await _authService.logout();
      throw Exception('Authentication required. Please login.');
    }

    Map<String, String> headers = {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json',
      ...(currentHeaders ?? {}),
    };

    http.Response response = await http.get(Uri.parse(url), headers: headers);

    if (response.statusCode == 401) { // Token expirado o inválido
      print('Access token expired or invalid (401). Attempting refresh...');
      accessToken = await refreshAccessToken(); // Intenta refrescar el token
      if (accessToken != null) {
        print('Token refreshed. Retrying original request to $url');
        headers['Authorization'] = 'Bearer $accessToken';
        response = await http.get(Uri.parse(url), headers: headers); // Reintenta la solicitud
      } else {
        print('Failed to refresh token. Original request to $url failed permanently due to auth.');
        // El refreshAccessToken ya maneja el logout si falla catastróficamente.
        // Aquí podrías lanzar una excepción para que la UI reaccione si es necesario.
        throw Exception('Session expired. Please login again.');
      }
    }
    return response;
  }

  Future<List<Map<String, dynamic>>> getDriveItems({
    String? folderId,
    String? driveId,
  }) async {
    final token = await getToken();
    if (token == null) {
      // Si no hay token, no podemos hacer la solicitud.
      print('Error: No access token found for getDriveItems');
      // _makeAuthenticatedGetRequest se encargará de esto, pero es una buena doble verificación.
      return [];
    }

    String initialUrl;
    if (driveId != null && folderId != null) {
      // Carpeta dentro de un drive compartido
      initialUrl = "https://graph.microsoft.com/v1.0/drives/$driveId/items/$folderId/children?\$expand=thumbnails";
    } else if (folderId != null) {
      // Carpeta en tu propio drive
      initialUrl = "$_baseUrl/items/$folderId/children?\$expand=thumbnails";
    } else {
      // Root de tu propio drive
      initialUrl = "$_baseUrl/root/children?\$expand=thumbnails";
    }

    List<Map<String, dynamic>> allItems = [];
    String? nextLink = initialUrl;

    while (nextLink != null) {
      final response = await _makeAuthenticatedGetRequest(nextLink); // Usar el wrapper
      if (response.statusCode == 200) {
        final Map<String, dynamic> jsonResponse = json.decode(response.body);
        final List<Map<String, dynamic>> currentItems =
            List<Map<String, dynamic>>.from(jsonResponse['value']);
        allItems.addAll(currentItems);

        // Verificar si hay una página siguiente
        nextLink = jsonResponse['@odata.nextLink'];
      } else {
        // Si _makeAuthenticatedGetRequest no pudo resolver un 401, o es otro error.
        print('Error al obtener archivos (después de posible reintento): ${response.statusCode} ${response.body}');
        throw Exception('Error al obtener archivos: ${response.statusCode} ${response.body}');
      }
    }

    // Añadir archivos compartidos solo si estamos en el root del propio drive y la solicitud inicial fue para el root.
    if (folderId == null && driveId == null) {
      // Nota: La URL para sharedWithMe también debería usar _makeAuthenticatedGetRequest
      // Por simplicidad, y asumiendo que no es una llamada tan frecuente como para paginarla aquí,
      // la dejamos con http.get directo, pero idealmente también usaría el wrapper.
      // Para una solución más robusta, considera paginar sharedWithMe también.
      final sharedResponse = await _makeAuthenticatedGetRequest("$_baseUrl/sharedWithMe");
      // La API de sharedWithMe también puede estar paginada, aunque es menos común para la mayoría de los usuarios tener >200 elementos compartidos directamente.
      // Para una solución completa, también deberías paginar aquí si es necesario.
      // Por simplicidad, este ejemplo asume que sharedWithMe devuelve todo en una página o que la paginación no es crítica aquí.
      if (sharedResponse.statusCode == 200) {
        final Map<String, dynamic> sharedJson = json.decode(sharedResponse.body);
        final List<Map<String, dynamic>> sharedItems =
            List<Map<String, dynamic>>.from(sharedJson['value']);
        allItems.addAll(sharedItems); // Añadir los compartidos a los normales
      } else {
        // Si no se pudieron obtener los compartidos, puedes ignorarlo o lanzar un error si prefieres
        print("Error al obtener archivos compartidos: ${sharedResponse.statusCode} ${sharedResponse.body}");
      }
    }

    return allItems;
  }
}