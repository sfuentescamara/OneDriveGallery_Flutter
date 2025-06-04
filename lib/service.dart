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
    List<dynamic> files = [];
    String? nextLinkRoot = "$_baseUrl/root/children?\$expand=thumbnails";
    String? nextLinkShared = "$_baseUrl/sharedWithMe?\$expand=thumbnails";

    try {
      // Solicitar archivos de la carpeta raíz con paginación y refresh de token
      while (nextLinkRoot != null) {
        final response = await sendAuthenticatedGetRequest(nextLinkRoot);
        if (response.statusCode == 200) {
          var data = jsonDecode(response.body);
          files.addAll(data['value']);
          nextLinkRoot = data['@odata.nextLink'];
        } else {
          print('Failed to load root files: ${response.statusCode}');
          nextLinkRoot = null; // Detener en caso de error
        }
      }

      // Obtener archivos compartidos con paginación y refresh de token
      while (nextLinkShared != null) {
        final sharedResponse = await sendAuthenticatedGetRequest(nextLinkShared);
        if (sharedResponse.statusCode == 200) {
          var sharedData = jsonDecode(sharedResponse.body);
          files.addAll(sharedData['value'].map((item) => item['remoteItem'] ?? item).toList()); // Extraer remoteItem si existe
          nextLinkShared = sharedData['@odata.nextLink'];
        }
      }
    } catch (e) {
      print('Error fetching files: $e');
    }

    return files;
  }

  // Wrapper para realizar solicitudes GET autenticadas con manejo de refresh token
  // Lo hacemos público para que pueda ser usado por _fetchItemsAsStream en drive_screen.dart
  Future<http.Response> sendAuthenticatedGetRequest(String url, {Map<String, String>? currentHeaders}) async {
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
      final response = await sendAuthenticatedGetRequest(nextLink); // Usar el wrapper
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
      String? nextLinkShared = "$_baseUrl/sharedWithMe?\$expand=thumbnails";
      while (nextLinkShared != null) {
        final sharedResponse = await sendAuthenticatedGetRequest(nextLinkShared);
        if (sharedResponse.statusCode == 200) {
          final Map<String, dynamic> sharedJson = json.decode(sharedResponse.body);
          final List<Map<String, dynamic>> sharedItemsContainers =
              List<Map<String, dynamic>>.from(sharedJson['value']);
          
          // Los items compartidos a menudo están dentro de 'remoteItem'
          for (var container in sharedItemsContainers) {
            if (container['remoteItem'] is Map<String, dynamic>) {
              allItems.add(container['remoteItem'] as Map<String, dynamic>);
            }
          }
          nextLinkShared = sharedJson['@odata.nextLink'];
        } else {
          print("Error al obtener archivos compartidos: ${sharedResponse.statusCode} ${sharedResponse.body}");
          nextLinkShared = null; // Detener en caso de error
          // Considerar si lanzar una excepción o continuar sin los compartidos
        }
      }
    }

    return allItems;
  }

  Future<Map<String, dynamic>> getFolderMetadataSummary({
    String? folderId,
    String? driveId,
  }) async {
    int totalItems = 0;
    int imageItems = 0;
    int folderItemsCount = 0; // Renombrado para evitar colisión con la variable folderId
    DateTime? folderCreatedDate;
    DateTime? folderLastModifiedDate;

    String folderDetailsRelativeUrl;
    String imageCountRelativeUrl;
    String folderCountRelativeUrl;

    if (driveId != null && folderId != null) { // Carpeta en un drive compartido
      folderDetailsRelativeUrl = "/drives/$driveId/items/$folderId?\$select=id,name,folder,createdDateTime,lastModifiedDateTime";
      imageCountRelativeUrl = "/drives/$driveId/items/$folderId/children?\$filter=image ne null&\$count=true&\$top=0";
      folderCountRelativeUrl = "/drives/$driveId/items/$folderId/children?\$filter=folder ne null&\$count=true&\$top=0";
    } else if (folderId != null) { // Carpeta en el drive del usuario
      folderDetailsRelativeUrl = "/me/drive/items/$folderId?\$select=id,name,folder,createdDateTime,lastModifiedDateTime";
      imageCountRelativeUrl = "/me/drive/items/$folderId/children?\$filter=image ne null&\$count=true&\$top=0";
      folderCountRelativeUrl = "/me/drive/items/$folderId/children?\$filter=folder ne null&\$count=true&\$top=0";
    } else { // Root del drive del usuario
      folderDetailsRelativeUrl = "/me/drive/root?\$select=id,name,folder,createdDateTime,lastModifiedDateTime";
      imageCountRelativeUrl = "/me/drive/root/children?\$filter=image ne null&\$count=true&\$top=0";
      folderCountRelativeUrl = "/me/drive/root/children?\$filter=folder ne null&\$count=true&\$top=0";
    }

    try {
      final batchRequestBody = {
        "requests": [
          {
            "id": "1",
            "method": "GET",
            "url": folderDetailsRelativeUrl
          },
          {
            "id": "2",
            "method": "GET",
            "url": imageCountRelativeUrl
          },
          {
            "id": "3",
            "method": "GET",
            "url": folderCountRelativeUrl
          }
        ]
      };

      final batchResponse = await _makeAuthenticatedPostRequest("https://graph.microsoft.com/v1.0/\$batch", json.encode(batchRequestBody));

      if (batchResponse.statusCode == 200) {
        final batchResults = json.decode(batchResponse.body);
        for (var responseItem in batchResults['responses']) {
          if (responseItem['status'] == 200) {
            final body = responseItem['body'];
            if (responseItem['id'] == '1') { // Folder details
              totalItems = body['folder']?['childCount'] ?? 0;
              if (body['createdDateTime'] != null) {
                folderCreatedDate = DateTime.tryParse(body['createdDateTime']);
              }
              if (body['lastModifiedDateTime'] != null) {
                folderLastModifiedDate = DateTime.tryParse(body['lastModifiedDateTime']);
              }
            } else if (responseItem['id'] == '2') { // Image count
              imageItems = body['@odata.count'] ?? 0;
            } else if (responseItem['id'] == '3') { // Folder count
              folderItemsCount = body['@odata.count'] ?? 0;
            }
          } else {
            print("Error in batch request item ${responseItem['id']}: ${responseItem['status']} ${responseItem['body']}");
          }
        }
      } else {
        print("Error in \$batch request: ${batchResponse.statusCode} ${batchResponse.body}");
        // Podrías lanzar una excepción aquí o intentar un fallback si es crítico
        throw Exception("Failed to load folder metadata via batch: ${batchResponse.statusCode}");
      }
    } catch (e) {
      print("Exception in getFolderMetadataSummary: $e");
      throw Exception("Failed to load folder metadata: $e");
    }

    // Asegúrate de que los conteos sean no nulos antes de restar
    totalItems = totalItems; // Ya asignado
    imageItems = imageItems;
    folderItemsCount = folderItemsCount;
    int otherFileItems = totalItems - imageItems - folderItemsCount;    
    if (otherFileItems < 0) otherFileItems = 0;

    return {
      'totalItems': totalItems,
      'imageItems': imageItems,
      'folderItems': folderItemsCount,
      'otherFileItems': otherFileItems,
      'folderCreatedDate': folderCreatedDate,
      'folderLastModifiedDate': folderLastModifiedDate,
    };
  }

  // Wrapper para realizar solicitudes POST autenticadas (necesario para $batch)
  Future<http.Response> _makeAuthenticatedPostRequest(String url, dynamic body, {Map<String, String>? currentHeaders}) async {
    String? accessToken = await getToken();
    if (accessToken == null) {
      throw Exception('Authentication required. Please login.');
    }

    Map<String, String> headers = {
      'Authorization': 'Bearer $accessToken',
      'Content-Type': 'application/json', // Batch requests son JSON
      ...(currentHeaders ?? {}),
    };

    http.Response response = await http.post(Uri.parse(url), headers: headers, body: body);

    if (response.statusCode == 401) { // Token expirado o inválido
      print('Access token expired or invalid (401) during POST. Attempting refresh...');
      accessToken = await refreshAccessToken();
      if (accessToken != null) {
        print('Token refreshed. Retrying original POST request to $url');
        headers['Authorization'] = 'Bearer $accessToken';
        response = await http.post(Uri.parse(url), headers: headers, body: body);
      } else {
        print('Failed to refresh token. Original POST request to $url failed permanently due to auth.');
        throw Exception('Session expired. Please login again.');
      }
    }
    return response;
  }

}