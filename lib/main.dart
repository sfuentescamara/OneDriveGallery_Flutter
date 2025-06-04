import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:convert'; // Para jsonEncode y jsonDecode
import 'package:shared_preferences/shared_preferences.dart'; // Para SharedPreferences
import 'package:intl/date_symbol_data_local.dart'; // Para inicializar datos de formato de fecha
 

// Nuevas importaciones para los archivos separados
import 'service.dart';
import 'login_screen.dart';
import 'favorite_screen.dart';
import 'drive_screen.dart';


Future<void> main() async {
  await dotenv.load(fileName: ".env");
  await initializeDateFormatting('es_ES', null); // Inicializar datos para español
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
  // Variables y métodos para la funcionalidad de carpetas favoritas
  List<FavoriteFolderIdentifier> _favoriteFolders = [];
  List<FavoriteFolderIdentifier> get favoriteFolders => _favoriteFolders;

  FavoriteFolderIdentifier? _folderToOpenFromFavorites;
  FavoriteFolderIdentifier? get folderToOpenFromFavorites => _folderToOpenFromFavorites;

  // Este selectedIndex es para que openFolderFromFavorites pueda cambiar a la pestaña del explorador.
  // _MyHomePageState también tiene su propio _selectedIndex para la UI.
  // Considera si esta lógica de navegación podría centralizarse o si está bien así.
  int _appWideSelectedIndex = 1; // Por defecto a la pestaña de Drive (índice 1)
  int get appWideSelectedIndex => _appWideSelectedIndex;

  // Clave para SharedPreferences
  static const String _favoritesKey = 'favoriteFolders';

  void toggleFavoriteFolder(FavoriteFolderIdentifier folder) {
    final isCurrentlyFavorite = _favoriteFolders.any((f) => f.id == folder.id && f.driveId == folder.driveId);
    if (isCurrentlyFavorite) {
      _favoriteFolders.removeWhere((f) => f.id == folder.id && f.driveId == folder.driveId);
    } else {
      _favoriteFolders.add(folder);
    }
    _saveFavoriteFolders(); // Llama a un método para persistir si lo implementas
    notifyListeners();
  }

  void removeFavoriteFolder(FavoriteFolderIdentifier folder) {
    _favoriteFolders.removeWhere((f) => f.id == folder.id && f.driveId == folder.driveId);
    _saveFavoriteFolders();
    notifyListeners();
  }

  bool isFavoriteFolder(FavoriteFolderIdentifier folder) {
    return _favoriteFolders.any((f) => f.id == folder.id && f.driveId == folder.driveId);
  }

  // Método para ser llamado desde FavoriteScreen
  void openFolderFromFavorites(FavoriteFolderIdentifier folder) {
    _folderToOpenFromFavorites = folder;
    // Cambia al índice de la pantalla del explorador de OneDrive
    // El índice 1 corresponde a OneDriveExplorer en _MyHomePageState._pages
    _appWideSelectedIndex = 1; 
    notifyListeners();
  }

  // Método para ser llamado por OneDriveExplorer después de abrir la carpeta
  void clearFolderToOpenFromFavorites() {
    _folderToOpenFromFavorites = null;
    // No es necesario notificar aquí usualmente, para evitar re-renders innecesarios.
  }

  // Si necesitas cambiar la pestaña desde otro lugar a través de MyAppState
  void setAppWideCurrentPageIndex(int index) {
    _appWideSelectedIndex = index;
    notifyListeners();
  }

  // Métodos para persistencia
  Future<void> _loadFavoriteFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? favoritesJson = prefs.getStringList(_favoritesKey);
    if (favoritesJson != null) {
      _favoriteFolders = favoritesJson.map((jsonString) {
        try {
          final Map<String, dynamic> jsonMap = jsonDecode(jsonString);
          return FavoriteFolderIdentifier.fromJson(jsonMap);
        } catch (e) {
          print("Error decoding favorite folder JSON: $e");
          return null; // Ignorar entradas inválidas
        }
      }).whereType<FavoriteFolderIdentifier>().toList(); // Filtrar nulos
      notifyListeners(); // Notificar después de cargar
    }
  }

  Future<void> _saveFavoriteFolders() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String> favoritesJson = _favoriteFolders.map((folder) => jsonEncode(folder.toJson())).toList();
    await prefs.setStringList(_favoritesKey, favoritesJson);
  }
}

class MyHomePage extends StatefulWidget {
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _selectedIndex = 1; // Iniciar en la pestaña de Drive (índice 1) por defecto o tras login
  bool _isLoading = true;

  // Lista de widgets para las páginas. Se instancian una vez.
  late List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    _pages = [
      LoginScreen(),
      OneDriveExplorer(), // Se crea una sola vez y se mantiene su estado
      FavoriteScreen(),
    ];
    _checkLoginStatus();
    // Escuchar cambios en appWideSelectedIndex de MyAppState
    // para actualizar la UI de BottomNavigationBar si el cambio viene de MyAppState.
    // Es importante remover el listener en dispose.

    // Cargar favoritos al iniciar la aplicación
    Provider.of<MyAppState>(context, listen: false)._loadFavoriteFolders();

    Provider.of<MyAppState>(context, listen: false).addListener(_onAppWideSelectedIndexChanged);
  }

  @override
  void dispose() {
    Provider.of<MyAppState>(context, listen: false).removeListener(_onAppWideSelectedIndexChanged);
    super.dispose();
  }

  void _checkLoginStatus() async {
    final authService = Provider.of<AuthService>(context, listen: false);
    bool isLoggedIn = await authService.isLoggedIn;
    final myAppState = Provider.of<MyAppState>(context, listen: false);

    setState(() {
      _selectedIndex = isLoggedIn ? myAppState.appWideSelectedIndex : 0; // 0: Login
      _isLoading = false;
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
    // También actualiza el índice en MyAppState si quieres que sea la fuente de verdad
    // o si otras partes de la app necesitan saber la pestaña actual a través de MyAppState.
    Provider.of<MyAppState>(context, listen: false).setAppWideCurrentPageIndex(index);
  }

  void _onAppWideSelectedIndexChanged() {
    final myAppState = Provider.of<MyAppState>(context, listen: false);
    if (_selectedIndex != myAppState.appWideSelectedIndex) {
      setState(() {
        _selectedIndex = myAppState.appWideSelectedIndex;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text("OneDrive Gallery"),
      ),
      body: IndexedStack( // Usar IndexedStack para mantener el estado de las pestañas
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
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

// En main.dart o un archivo de modelos (ej: models.dart)
class FavoriteFolderIdentifier {
  final String id; // ID de la carpeta, o "root" para la raíz del drive principal
  final String? driveId; // driveId si es una carpeta en un drive compartido
  final String name; // Nombre de la carpeta para mostrar

  FavoriteFolderIdentifier({required this.id, this.driveId, required this.name});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FavoriteFolderIdentifier &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          driveId == other.driveId;

  @override
  int get hashCode => id.hashCode ^ (driveId?.hashCode ?? 0);

  // Opcional: para persistencia si guardas los favoritos
  Map<String, dynamic> toJson() => {
        'id': id,
        'driveId': driveId,
        'name': name,
      };

  factory FavoriteFolderIdentifier.fromJson(Map<String, dynamic> json) =>
      FavoriteFolderIdentifier(
        id: json['id'],
        driveId: json['driveId'],
        name: json['name'],
      );
}
