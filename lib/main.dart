import 'package:english_words/english_words.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';
import 'package:flutter_image_gallery_saver/flutter_image_gallery_saver.dart';

Future<void> main() async {
  await dotenv.load(fileName: ".env");
  final authService = AuthService();
  final graphService = GraphService();
  graphService.init(authService); // Inyectamos AuthService

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => authService),
        Provider(create: (_) => graphService),
      ],
      child: MyApp(),
    ),
  );
}

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
  Future<void> saveToken(String token) async {
    await _storage.write(key: 'access_token', value: token);
  }

  // Leer token de acceso
  Future<String?> getToken() async {
    return await _storage.read(key: 'access_token');
  }

  // Verificar si hay un token guardado y si es válido
  Future<bool> get isLoggedIn async {
    String? token = await getToken();
    return token != null && token.isNotEmpty; // Si el token no es nulo ni vacío, está logueado
  }

  // Método para cerrar sesión
  Future<void> logout() async {
    await _storage.delete(key: 'access_token');
    notifyListeners(); // Notifica cambios
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

  final String  clientId = dotenv.env['CLIENT_ID'] ?? '';
  final String  tenantId = dotenv.env['TENANT_ID'] ?? '';
  final List<String>  scope = ['User.Read', "Files.ReadWrite.All", "Files.Read.All"];
  final String  redirectUri = 'com.example.onedrivegallery://auth';
  final String  authorizationEndpoint = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize';
  final String  tokenEndpoint = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/token';
  final String  endSessionEndpoint = 'https://login.microsoftonline.com/consumers/oauth2/v2.0/logout';

  // Guardar token de acceso
  Future<String?> requestToken() async {
    try {
      final AuthorizationTokenResponse? result = await appAuth.authorizeAndExchangeCode(
            AuthorizationTokenRequest(
              clientId,
              redirectUri,
              serviceConfiguration: AuthorizationServiceConfiguration(authorizationEndpoint: authorizationEndpoint,  tokenEndpoint: tokenEndpoint, endSessionEndpoint: endSessionEndpoint),
              scopes: scope,
            ),
      );
      if (result != null && result.accessToken != null) {
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

  Future<List<Map<String, dynamic>>> getDriveItems({
    String? folderId,
    String? driveId,
  }) async {
    final token = await getToken();
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    
    String url;
    if (driveId != null && folderId != null) {
    // Carpeta dentro de un drive compartido
      url = "https://graph.microsoft.com/v1.0/drives/$driveId/items/$folderId/children?\$expand=thumbnails";
    } else if (folderId != null) {
      // Carpeta en tu propio drive
      url = "$_baseUrl/items/$folderId/children?\$expand=thumbnails";
    } else {
      // Root de tu propio drive
      url = "$_baseUrl/root/children?\$expand=thumbnails";
    }

    // Obtener archivos del directorio (root o carpeta específica)
    final response = await http.get(Uri.parse(url), headers: headers);
    if (response.statusCode != 200) {
      throw Exception('Error al obtener archivos: ${response.statusCode} ${response.body}');
    }
    final Map<String, dynamic> jsonResponse = json.decode(response.body);
    final List<Map<String, dynamic>> items =
        List<Map<String, dynamic>>.from(jsonResponse['value']);

    // Añadir archivos compartidos solo si estamos en el root del propio drive
  if (folderId == null && driveId == null) {
      final sharedResponse = await http.get(
        Uri.parse("$_baseUrl/sharedWithMe"),
        headers: headers,
      );

      if (sharedResponse.statusCode == 200) {
        final Map<String, dynamic> sharedJson = json.decode(sharedResponse.body);
        final List<Map<String, dynamic>> sharedItems =
            List<Map<String, dynamic>>.from(sharedJson['value']);
        items.addAll(sharedItems); // Añadir los compartidos a los normales
      } else {
        // Si no se pudieron obtener los compartidos, puedes ignorarlo o lanzar un error si prefieres
        print("Error al obtener archivos compartidos: ${sharedResponse.statusCode} ${sharedResponse.body}");
      }
    }

    return items;
  }

}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => MyAppState(),
      child: MaterialApp(
        title: 'Namer App',
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color.fromARGB(255, 17, 67, 205)),
        ),
        home: MyHomePage(),
      ),
    );
  }
}

class MyAppState extends ChangeNotifier {
  var current = WordPair.random();  // ↓ Add this.
  void getNext() {
    current = WordPair.random();
    notifyListeners();
  }
  var favorites = <WordPair>[];  void toggleFavorite(word) {
    if (favorites.contains(word)) {
      favorites.remove(word);
    } else {
      favorites.add(word);
    }
    notifyListeners();
  }

}

class MyHomePage extends StatefulWidget {
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int? _selectedIndex; // Puede ser null durante la pantalla de carga
  bool _isLoading = true;

  // List of pages for each destination
  static List<Widget> _pages = <Widget>[
    LoginScreen(), // Página para el perfil
    OneDriveExplorer(), // Página de fotos
    FavoriteScreen(), // Página de explorar
  ];

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  void _checkLoginStatus() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    bool isLoggedIn = await authService.isLoggedIn;
    
    setState(() {
      _selectedIndex = isLoggedIn ? 1 : 0; // 1: Drive, 0: Login
      _isLoading = false;
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _selectedIndex == null) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text("OneDrive Gallery"),
      ),
      body: _pages[_selectedIndex!],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex!,
        onTap: _onItemTapped,
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Perfil',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.photo),
            label: 'Drive',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bookmark),
            label: 'Favoritos',
          ),
        ],
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isLoading = false; // Variable para controlar el estado de carga

  @override
  Widget build(BuildContext context) {
    final authService = Provider.of<AuthService>(context);
    final graphService = Provider.of<GraphService>(context, listen: false);


    return Scaffold(
      appBar: AppBar(title: Text("Login")),
      body: Center(
        child: FutureBuilder<bool>(
          future: authService.isLoggedIn,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return CircularProgressIndicator(); // Cargando estado de login
            }

            final isLoggedIn = snapshot.data ?? false;

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Muestra información del usuario si está logueado
                if (isLoggedIn) 
                  Text("Usuario logueado", style: TextStyle(fontSize: 18)),
                
                // Si está cargando, muestra el CircularProgressIndicator
                if (_isLoading)
                  CircularProgressIndicator(),
                
                ElevatedButton(
                  onPressed: () async {
                    if (_isLoading) return; // Evita hacer login/logout si ya está cargando

                    setState(() {
                      _isLoading = true; // Inicia el estado de carga
                    });

                    if (isLoggedIn) {
                      await authService.logout();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Sesión cerrada")),
                      );
                    } else {
                      String? token = await graphService.requestToken();
                      if (token != null) {
                        await authService.saveToken(token);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("Sesión iniciada")),
                        );
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text("Error al iniciar sesión")),
                        );
                      }
                    }

                    setState(() {
                      _isLoading = false; // Finaliza el estado de carga
                    });
                  },
                  child: Text(isLoggedIn ? 'Cerrar sesión' : 'Iniciar sesión'),
                ),
              ]
            );
          },
        ),
      ),
    );
  }
}

class FavoriteScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    return ListView(
        children: [
          
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text('You have '
                '${appState.favorites.length} favorites:'),
          ),

        for (var element in appState.favorites) 
            ElevatedButton.icon(
              onPressed: () {
                appState.toggleFavorite(element);
              },
              icon: Icon(Icons.favorite),
              label: Text(element.asLowerCase),
            ),
      ],
    );
  }
}


class DriveScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {

    return FutureBuilder<List<dynamic>>(
      future: GraphService().getDriveFiles(), // Obtenemos los archivos
      builder: (context, fileSnapshot) {
        if (fileSnapshot.connectionState == ConnectionState.waiting) {
          return Center(child: CircularProgressIndicator());
        } else if (fileSnapshot.hasError) {
          return Center(child: Text('Error: ${fileSnapshot.error}'));
        } else if (!fileSnapshot.hasData || fileSnapshot.data!.isEmpty) {
          return Center(child: Text('No files found'));
        }

        List<dynamic> items = fileSnapshot.data!.map((json) {
          if (json.containsKey('folder')) {
            return OneDriveFolder.fromJson(json);
          } else if (json.containsKey('file')) {
            return OneDriveFile.fromJson(json);
          } else {
            return null;
          }
        }).where((item) => item != null).toList();
        
        // Mostramos los archivos
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];

            if (item is OneDriveFolder) {
              return ListTile(
                leading: Icon(Icons.folder),
                title: Text(item.name),
                subtitle: Text('Carpeta (${item.childCount} elementos)'),
                onTap: () {
                  // Aquí podrías navegar a una vista con el contenido de la carpeta
                  print('Abrir carpeta: ${item.name}');
                },
              );
            } else if (item is OneDriveFile) {
              return ListTile(
                leading: Icon(Icons.insert_drive_file),
                title: Text(item.name),
                subtitle: Text('Archivo - ${item.size} bytes'),
                onTap: () {
                  // Aquí podrías abrir o descargar el archivo
                  print('Abrir archivo: ${item.name}');
                },
              );
            } else {
              return SizedBox.shrink(); // O algún mensaje de error
            }
          },
        );

      },
    );
  }
}



class OneDriveExplorer extends StatefulWidget {
  @override
  _OneDriveExplorerState createState() => _OneDriveExplorerState();
}

class _OneDriveExplorerState extends State<OneDriveExplorer> {
  final List<OneDriveFolder> _folderStack = []; // Historial de carpetas
  late Future<List<dynamic>> _itemsFuture;
  late String? _folderName = 'OneDrive Explorer'; // Nombre de la carpeta actual
  late OneDriveGallery _gallery = OneDriveGallery(imagesByDate: {}); // Galería de imágenes

  @override
  void initState() {
    super.initState();
    _itemsFuture = _fetchItems(); // Carga del directorio raíz
  }

  Future<List<dynamic>> _fetchItems({String? folderId, String? driveId}) async {
    final graphService = Provider.of<GraphService>(context, listen: false);
    final itemsJson = await graphService.getDriveItems(folderId: folderId, driveId: driveId);
    List<dynamic> items = [];
    bool hasImages = false;

      items = itemsJson.map((json) {
      if (json.containsKey('folder')) {
        return OneDriveFolder.fromJson(json);
      } else if (json.containsKey('image')) {
        hasImages = true;
      } else if (json.containsKey('file')) {
        return OneDriveFile.fromJson(json);
      } else {
        return null;
      }
    }).whereType<dynamic>().toList();

    if (hasImages) {
      _gallery = OneDriveGallery.fromDriveItems(itemsJson); // Agrupamos las imágenes por fecha
      items.add(_gallery); // Añadimos la galería al final de la lista
    }
    return items;
  }

  void _enterFolder(OneDriveFolder folder) {
    _folderName = folder.name; // Actualiza el nombre de la carpeta
    _folderStack.add(folder);
    setState(() {
      _itemsFuture = _fetchItems(folderId: folder.id, driveId: folder.driveId);
    });
  }

  void _goBack() {
    if (_folderStack.isNotEmpty) {
      _folderStack.removeLast();
      OneDriveFolder? folder = _folderStack.isNotEmpty ? _folderStack.last : null;
      _folderName = folder?.name; // Actualiza el nombre de la carpeta
      String? folderId = folder?.id;
      String? driveId = folder?.driveId;

      setState(() {
        _itemsFuture = _fetchItems(folderId: folderId, driveId: driveId);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_folderName ?? 'OneDrive Explorer'),
        leading: _folderStack.isNotEmpty
            ? IconButton(
                icon: Icon(Icons.arrow_back),
                onPressed: _goBack,
              )
            : null,
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _itemsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error al cargar: ${snapshot.error}'));
          }

          final items = snapshot.data!;
          if (items.isEmpty) {
            return Center(child: Text('Carpeta vacía'));
          }

          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];

              if (item is OneDriveFolder) {
                return ListTile(
                  leading: Icon(Icons.folder),
                  title: Text(item.name),
                  subtitle: Text('${item.childCount} elementos'),
                  onTap: () => _enterFolder(item),
                );
              } else if (item is OneDriveFile) {
                return ListTile(
                  leading: Icon(Icons.insert_drive_file),
                  title: Text(item.name),
                  subtitle: Text('${item.size} bytes'),
                  onTap: () {
                    // Aquí podrías abrir o descargar el archivo
                  },
                );
              } else if (item is OneDriveGallery) {
                // Renderiza la galería de imágenes
                return OneDriveGalleryWidget(gallery: item);
              } else {
                return SizedBox.shrink();
              }
            },
          );
        },
      ),
    );
  }
}



class OneDriveFolder {
  final String id;
  final String name;
  final DateTime createdDateTime;
  final int childCount;
  final String driveId;

  OneDriveFolder({
    required this.id,
    required this.name,
    required this.createdDateTime,
    required this.childCount,
    required this.driveId,
  });

  factory OneDriveFolder.fromJson(Map<String, dynamic> json) {
    return OneDriveFolder(
      id: json['id'],
      name: json['name'],
      createdDateTime: DateTime.parse(json['createdDateTime']),
      childCount: json['folder']?['childCount'] ?? 0,
      driveId: json['parentReference']?['driveId'] ?? json['remoteItem']?['parentReference']?['driveId'],
    );
  }
}

class OneDriveFile {
  final String id;
  final String name;
  final DateTime createdDateTime;
  final int size;
  final String? downloadUrl;

  OneDriveFile({
    required this.id,
    required this.name,
    required this.createdDateTime,
    required this.size,
    this.downloadUrl,
  });

  factory OneDriveFile.fromJson(Map<String, dynamic> json) {
    return OneDriveFile(
      id: json['id'],
      name: json['name'],
      createdDateTime: DateTime.parse(json['createdDateTime']),
      size: json['size'],
      downloadUrl: json['@microsoft.graph.downloadUrl'], // Solo está disponible para archivos
    );
  }
}

class OneDriveImage {
  final String id;
  final String name;
  final String downloadUrl;
  final String thumbnailUrl;
  final String thumbnailUrlLarge;
  final DateTime takenDateTime;

  OneDriveImage({
    required this.id,
    required this.name,
    required this.downloadUrl,
    required this.thumbnailUrl,
    required this.thumbnailUrlLarge,
    required this.takenDateTime,
  });

  factory OneDriveImage.fromJson(Map<String, dynamic> json) {
    return OneDriveImage(
      id: json['id'],
      name: json['name'],
      downloadUrl: json['@microsoft.graph.downloadUrl'],
      thumbnailUrl: json['thumbnails'] != null && json['thumbnails'].isNotEmpty
          ? json['thumbnails'][0]['small']['url']
          : '',
      thumbnailUrlLarge: json['thumbnails'] != null && json['thumbnails'].isNotEmpty
          ? json['thumbnails'][0]['large']['url']
          : '',
      takenDateTime: DateTime.tryParse(json['photo']['takenDateTime'] ?? '') ?? DateTime.tryParse(json['CreatedDateTime']?? '') ?? DateTime(1970), // default
    );
  }
}


class OneDriveGallery {
  final Map<String, List<OneDriveImage>> imagesByDate;

  OneDriveGallery({required this.imagesByDate});

  factory OneDriveGallery.fromDriveItems(List<Map<String, dynamic>> items) {
    final Map<String, List<OneDriveImage>> groupedImages = {};

    for (var item in items) {
      if (item.containsKey('image')) {
        final image = OneDriveImage.fromJson(item);
        final createdDate = DateTime.tryParse(item['photo']['takenDateTime'] ?? '') ?? DateTime.tryParse(item['CreatedDateTime']?? '') ?? DateTime(1970); // default
        final dateKey = "${createdDate.year}-${createdDate.month.toString().padLeft(2, '0')}-${createdDate.day.toString().padLeft(2, '0')}";

        if (!groupedImages.containsKey(dateKey)) {
          groupedImages[dateKey] = [];
        }
        groupedImages[dateKey]!.add(image);
      }
    }

    return OneDriveGallery(imagesByDate: groupedImages);
  }
}

class OneDriveGalleryWidget extends StatefulWidget {
  final OneDriveGallery gallery;

  const OneDriveGalleryWidget({Key? key, required this.gallery}) : super(key: key);

  @override
  _OneDriveGalleryWidgetState createState() => _OneDriveGalleryWidgetState();
}

class _OneDriveGalleryWidgetState extends State<OneDriveGalleryWidget> {
  double columns = 4;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Slider(
          min: 3,
          max: 6,
          divisions: 4,
          label: '${columns.round()} columnas',
          value: columns,
          onChanged: (value) {
            setState(() {
              columns = value;
            });
          },
        ),
        ...widget.gallery.imagesByDate.entries.map((entry) {
          final date = entry.key;
          final images = entry.value;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16),
                child: Text(
                  date,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                itemCount: images.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns.round(),
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemBuilder: (context, index) {
                  final image = images[index];
                  return GestureDetector(
                    onTap: () {
                      showImageViewer(context, images, index); 
                    },
                    child: CachedNetworkImage(
                      imageUrl: image.thumbnailUrl.isNotEmpty ? image.thumbnailUrl : image.downloadUrl,
                      placeholder: (context, url) => Center(child: CircularProgressIndicator()),
                      errorWidget: (context, url, error) => Icon(Icons.broken_image),
                      fit: BoxFit.cover,
                    ),
                  );
                },
              ),
            ],
          );
        }).toList()
      ],
    );
  }
}

void showImageViewer(BuildContext context, List<OneDriveImage> images, int initialIndex) {
  showDialog(
    context: context,
    barrierColor: Colors.black.withOpacity(0.95),
    barrierDismissible: true,
    builder: (context) {
      PageController controller = PageController(initialPage: initialIndex);
      int currentIndex = initialIndex;

      return StatefulBuilder(
        builder: (subContext, setState) {
          return Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(
              children: [
                PageView.builder(
                  controller: controller,
                  itemCount: images.length,
                  onPageChanged: (index) => setState(() => currentIndex = index),
                  itemBuilder: (subContext, index) {
                    final image = images[index];
                    return InteractiveViewer(
                      panEnabled: true,
                      minScale: 1,
                      maxScale: 5,
                      child: Center(
                        child: Hero(
                          tag: image.id,
                          child: Image.network(
                            image.thumbnailUrlLarge.isNotEmpty ? image.thumbnailUrlLarge : image.downloadUrl,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Positioned(
                  top: MediaQuery.of(subContext).padding.top + 10,
                  left: 10,
                  child: IconButton(
                    icon: Icon(Icons.close, color: Colors.white, size: 28),
                    onPressed: () => Navigator.of(subContext).pop(),
                  ),
                ),
                Positioned(
                  bottom: MediaQuery.of(subContext).padding.bottom + 16,
                  right: 16,
                  child: FloatingActionButton(
                    mini: true,
                    backgroundColor: Colors.white70,
                    onPressed: () {
                      showModalBottomSheet(
                        context: subContext,
                        builder: (subContext) =>
                            _buildImageOptionsSheet(context, images[currentIndex]),
                        backgroundColor: Colors.white,
                      );
                    },
                    child: Icon(Icons.more_vert, color: Colors.black),
                  ),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}


Widget _buildImageOptionsSheet(BuildContext context, OneDriveImage image) {
  return Wrap(
    children: [
      ListTile(
        leading: Icon(Icons.download),
        title: Text('Descargar'),
        onTap: () async {
          Navigator.pop(context);
          Future.microtask(() {
            _downloadAndSaveImage(image, context); // se ejecuta en el siguiente ciclo de evento
          });
        },
      ),
      ListTile(
        leading: Icon(Icons.share),
        title: Text('Compartir'),
        onTap: () async {
          Navigator.pop(context);
          Future.microtask(() {
            _shareImage(image, context); // se ejecuta en el siguiente ciclo de evento
          });
        },
      ),
    ],
  );
}


Future<File> _downloadImage(OneDriveImage image) async {
  final dir = await getTemporaryDirectory(); // o getApplicationDocumentsDirectory()
  final filePath = '${dir.path}/${image.name}';

  final response = await Dio().download(image.downloadUrl, filePath);
  if (response.statusCode == 200) {
    return File(filePath);
  } else {
    throw Exception('Error al descargar imagen');
  }
}

Future<void> _shareImage(OneDriveImage image, BuildContext context) async {
  try {
    final file = await _downloadImage(image);
    await Share.shareXFiles([XFile(file.path)], text: image.name);
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error al compartir: $e')),
    );
  }
}

Future<void> _downloadAndSaveImage(OneDriveImage image, BuildContext context) async {
    try {
    // Pedir permiso si es necesario
    if (await Permission.storage.request().isGranted || await Permission.photos.request().isGranted) {
      final response = await http.get(Uri.parse(image.downloadUrl));
      if (response.statusCode == 200) {
        final Uint8List imageBytes = response.bodyBytes;

        await FlutterImageGallerySaver.saveImage(imageBytes);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imagen guardada en la galería')),
        );
      } else {
        throw 'No se pudo descargar la imagen (status ${response.statusCode})';
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Permiso denegado para guardar imagen')),
      );
    }
  } catch (e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error: $e')),
    );
  }
}

class BigCard extends StatelessWidget {
  const BigCard({
    super.key,
    required this.pair,
  });

  final WordPair pair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.displayMedium!.copyWith(
      color: theme.colorScheme.onPrimary,
    );    return Card(
      color: theme.colorScheme.primary,    // ← And also this.
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Text(
          pair.asLowerCase,
          style: style,
          semanticsLabel: "${pair.first} ${pair.second}",
        ),
      ),
    );
  }
}
