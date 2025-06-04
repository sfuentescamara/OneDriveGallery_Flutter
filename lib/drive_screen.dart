import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'service.dart'; // Importa el archivo de servicios
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import 'package:dio/dio.dart' as dio_package; // Renombrado para evitar conflicto con Dio de http
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:typed_data';
import 'package:flutter_image_gallery_saver/flutter_image_gallery_saver.dart';
import 'package:video_player/video_player.dart';
import 'main.dart'; // Para MyAppState y FavoriteFolderIdentifier


class DriveScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: Provider.of<GraphService>(context, listen: false).getDriveFiles(), // Obtenemos los archivos
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
  // Añadir el constructor con Key
  const OneDriveExplorer({Key? key}) : super(key: key);

  @override
  _OneDriveExplorerState createState() => _OneDriveExplorerState();
}

class _OneDriveExplorerState extends State<OneDriveExplorer> with AutomaticKeepAliveClientMixin<OneDriveExplorer> {
  @override
  bool get wantKeepAlive => true; // Para mantener el estado del widget

  final List<OneDriveFolder> _folderStack = []; // Historial de carpetas
  Stream<List<dynamic>>? _itemsStream;
  late String? _folderName = 'OneDrive Explorer'; // Nombre de la carpeta actual

  bool _isLoadingMetadata = true;
  Map<String, dynamic>? _folderMetadata;
  bool _isAtRealRoot = true; // Para rastrear si la vista actual es la raíz real de OneDrive
  FavoriteFolderIdentifier? _currentEntryPointInfo; // Información del punto de entrada actual (si es un favorito)
  String? _metadataError;

  @override
  void initState() {
    super.initState();
    // La carga inicial se hará si folderToOpenFromFavorites es null la primera vez
    // o si _handleOpenFromFavorites no se dispara con una carpeta específica.
    // Para asegurar la carga inicial si no hay navegación desde favoritos:
    final appState = Provider.of<MyAppState>(context, listen: false);
    if (appState.folderToOpenFromFavorites == null) {
      _currentEntryPointInfo = null; // La raíz es el punto de entrada
      _loadMetadataAndItems();
    }
    appState.addListener(_handleOpenFromFavorites);
  }

  @override
  void dispose() {
    Provider.of<MyAppState>(context, listen: false).removeListener(_handleOpenFromFavorites);
    super.dispose();
  }

  void _handleOpenFromFavorites() {
    final appState = Provider.of<MyAppState>(context, listen: false);
    if (appState.folderToOpenFromFavorites != null && mounted) {
      final folderToOpen = appState.folderToOpenFromFavorites!;

      // Opcional: Evitar recarga si ya estamos en la carpeta destino
      FavoriteFolderIdentifier? currentFolderId = _getCurrentFolderIdentifier();
      if (currentFolderId?.id == folderToOpen.id && currentFolderId?.driveId == folderToOpen.driveId) {
        appState.clearFolderToOpenFromFavorites(); // Limpiar la señal
        return; // Ya estamos aquí, no hacer nada más
      }

      setState(() { // Asegurar que los cambios de UI (como _folderName) se reflejen
        _currentEntryPointInfo = folderToOpen; // Establecer el favorito como punto de entrada
        _folderStack.clear();
        _folderName = folderToOpen.name;

        if (folderToOpen.id == 'root' && folderToOpen.driveId == null) {
          _loadMetadataAndItems();
        } else {
          _loadMetadataAndItems(folderId: folderToOpen.id, driveId: folderToOpen.driveId);
        }
      });
      appState.clearFolderToOpenFromFavorites();
    }
  }

  // didChangeDependencies se puede mantener si se usa para otras cosas,
  // pero la lógica de folderToOpenFromFavorites ahora está en _handleOpenFromFavorites.

  FavoriteFolderIdentifier? _getCurrentFolderIdentifier() {
    if (_folderStack.isEmpty) {
      // Raíz del drive personal
      return FavoriteFolderIdentifier(id: 'root', name: _folderName ?? 'OneDrive');
    } else {
      final currentFolder = _folderStack.last;
      return FavoriteFolderIdentifier(
        id: currentFolder.id,
        driveId: currentFolder.driveId, // driveId puede ser null
        name: currentFolder.name,
      );
    }
  }

  Future<void> _loadMetadataAndItems({String? folderId, String? driveId}) async {
    setState(() {
      _isLoadingMetadata = true;
      _folderMetadata = null;
      _metadataError = null;
      _itemsStream = null; // Reiniciar stream de items mientras carga metadata
      _isAtRealRoot = (folderId == null && driveId == null); // Actualiza si estamos en la raíz real
    });
    try {
      final graphService = Provider.of<GraphService>(context, listen: false);
      final metadata = await graphService.getFolderMetadataSummary(folderId: folderId, driveId: driveId);
      if (mounted) {
        setState(() {
          String? nameFromMetadata = metadata['name'] as String?;
          if (nameFromMetadata != null) {
            _folderName = nameFromMetadata;
          } else if (folderId == null && driveId == null) {
            _folderName = 'OneDrive Explorer'; // Asegurar el nombre de la raíz si metadata['name'] es nulo
          }
          // Si metadata['name'] es nulo y no es la raíz, mantenemos el _folderName
          // que ya se estableció en el método de navegación (_enterFolder, _goBack, _goToRoot).
        });

      }
      _itemsStream = _fetchItemsAsStream(folderId: folderId, driveId: driveId);
    } catch (e) {
      _metadataError = e.toString();
      print("Error loading metadata: $e");      
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMetadata = false;
        });
      }
    }
  }





  List<dynamic> _buildDisplayList(
    List<Map<String, dynamic>> childrenRawItems,
    List<Map<String, dynamic>> sharedRemoteRawItems,
  ) {
    List<Map<String, dynamic>> allCombinedRawItems = [];
    Map<String, Map<String, dynamic>> uniqueRawItemsMap = {};

    for (var item in childrenRawItems) {
      uniqueRawItemsMap[item['id']] = item;
    }
    for (var item in sharedRemoteRawItems) {
      uniqueRawItemsMap[item['id']] = item;
    }
    allCombinedRawItems = uniqueRawItemsMap.values.toList();

    List<dynamic> processedItems = [];
    List<Map<String, dynamic>> mediaItemsForGallery = [];

    // Populate processedItems with Folders and Files, collect media items separately
    for (var rawItem in allCombinedRawItems) {
      if (rawItem.containsKey('folder')) {
        processedItems.add(OneDriveFolder.fromJson(rawItem));
      } else if (rawItem.containsKey('image') || rawItem.containsKey('video')) {
        mediaItemsForGallery.add(rawItem); // Collect for single gallery
      } else if (rawItem.containsKey('file')) { // Other non-media files
        processedItems.add(OneDriveFile.fromJson(rawItem));
      }
    }

    // Create and add the single gallery object if there are media items
    if (mediaItemsForGallery.isNotEmpty) {
      OneDriveGallery gallery = OneDriveGallery.fromDriveItems(mediaItemsForGallery);
      if (gallery.mediaByDate.isNotEmpty) {
        processedItems.add(gallery);
      }
    }

    // Sort all items together
    processedItems.sort((a, b) {
      if (a is OneDriveFolder && !(b is OneDriveFolder)) return -1;
      if (!(a is OneDriveFolder) && b is OneDriveFolder) return 1;
      if (a is OneDriveFolder && b is OneDriveFolder) return a.name.compareTo(b.name);

      if (a is OneDriveFile && b is! OneDriveFile) return -1; // Files come after folders but before gallery
      if (a is! OneDriveFile && b is OneDriveFile) return 1;
      if (a is OneDriveFile && b is OneDriveFile) return a.name.compareTo(b.name);
      
      if (a is OneDriveGallery && b is! OneDriveGallery) return 1; // Gallery last
      if (a is! OneDriveGallery && b is OneDriveGallery) return -1;

      return 0;
    });
    return processedItems;
  }

  Stream<List<dynamic>> _fetchItemsAsStream({String? folderId, String? driveId}) async* {
    final graphService = Provider.of<GraphService>(context, listen: false);
    final String graphBaseUrl = "https://graph.microsoft.com/v1.0";
    // El token y los headers serán manejados por _makeAuthenticatedGetRequest (o su equivalente en GraphService)

    String childrenUrl;
    if (driveId != null && folderId != null) {
      childrenUrl = "$graphBaseUrl/drives/$driveId/items/$folderId/children?\$expand=thumbnails";
    } else if (folderId != null) {
      childrenUrl = "$graphBaseUrl/me/drive/items/$folderId/children?\$expand=thumbnails";
    } else {
      childrenUrl = "$graphBaseUrl/me/drive/root/children?\$expand=thumbnails";
    }

    List<Map<String, dynamic>> accumulatedRawItemsFromChildren = [];
    String? nextLinkChildren = childrenUrl;

    while (nextLinkChildren != null) {
      // Usar el método público de GraphService para realizar la solicitud autenticada.
      final http.Response rawResponse = await graphService.sendAuthenticatedGetRequest(nextLinkChildren);

      if (rawResponse.statusCode == 200) {
        final jsonResponse = json.decode(rawResponse.body);
        final List<Map<String, dynamic>> currentPageRawItems = List.from(jsonResponse['value']);
        accumulatedRawItemsFromChildren.addAll(currentPageRawItems);
        yield _buildDisplayList(accumulatedRawItemsFromChildren, []);
        nextLinkChildren = jsonResponse['@odata.nextLink'];
      } else {
        // El error (incluyendo 401 no resuelto) debería ser manejado por sendAuthenticatedGetRequest
        // o lanzar una excepción que el StreamBuilder pueda capturar.
        print('Error al obtener items de la carpeta (después de posible reintento): ${rawResponse.statusCode} ${rawResponse.body}');
        throw Exception('Error al obtener items de la carpeta: ${rawResponse.statusCode}');
      }
    }

    if (folderId == null && driveId == null) {
      List<Map<String, dynamic>> accumulatedRawSharedRemoteItems = [];
      String? nextLinkShared = "$graphBaseUrl/me/drive/sharedWithMe?\$expand=thumbnails";

      while (nextLinkShared != null) {
        final http.Response rawSharedResponse = await graphService.sendAuthenticatedGetRequest(nextLinkShared);
        if (rawSharedResponse.statusCode == 200) {
          final jsonResponse = json.decode(rawSharedResponse.body);
          final List<Map<String, dynamic>> currentPageSharedContainers = List.from(jsonResponse['value']);
          for (var container in currentPageSharedContainers) {
            if (container['remoteItem'] is Map<String, dynamic>) {
              accumulatedRawSharedRemoteItems.add(container['remoteItem'] as Map<String, dynamic>);
            }
          }
          yield _buildDisplayList(accumulatedRawItemsFromChildren, accumulatedRawSharedRemoteItems);
          nextLinkShared = jsonResponse['@odata.nextLink'];
        } else {
          print("Error al obtener archivos compartidos (después de posible reintento): ${rawSharedResponse.statusCode} ${rawSharedResponse.body}");
          nextLinkShared = null;
        }
      }
    }
  }

  void _enterFolder(OneDriveFolder folder) {
    _folderName = folder.name;
    _folderStack.add(folder);
    setState(() {
      _loadMetadataAndItems(folderId: folder.id, driveId: folder.driveId);
    });
  }

  void _goBack() {
    if (_folderStack.isNotEmpty) {
      setState(() {
        _folderStack.removeLast(); // Quita la carpeta actual de la pila
        if (_folderStack.isNotEmpty) {
          // Si la pila aún tiene elementos, el último es la carpeta a la que volvemos
          final parentFolderToDisplay = _folderStack.last;
          _folderName = parentFolderToDisplay.name; // Actualizar nombre inmediatamente
          _loadMetadataAndItems(folderId: parentFolderToDisplay.id, driveId: parentFolderToDisplay.driveId);
        } else {
          // La pila está vacía, volvemos al punto de entrada original (raíz o favorito)
          if (_currentEntryPointInfo != null) {
            _folderName = _currentEntryPointInfo!.name; // Actualizar nombre inmediatamente
            _loadMetadataAndItems(folderId: _currentEntryPointInfo!.id, driveId: _currentEntryPointInfo!.driveId);
          } else {
            // El punto de entrada era la raíz real
            _folderName = 'OneDrive Explorer'; // Nombre por defecto para la raíz
            _loadMetadataAndItems(folderId: null, driveId: null);
          }
        }
      });
    }
  }

  void _goToRoot() {
    setState(() {
      _currentEntryPointInfo = null; // La raíz es el nuevo punto de entrada
      _folderStack.clear();
      _folderName = 'OneDrive Explorer'; // Nombre por defecto para la raíz
      // Cargar metadatos y elementos para la raíz (sin folderId ni driveId)
      _loadMetadataAndItems();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Necesario para AutomaticKeepAliveClientMixin

    return WillPopScope(
      onWillPop: () async {
        if (_folderStack.isNotEmpty) {
          // Si hay una pila de navegación interna, maneja "Atrás" internamente.
          _goBack();
          return false; // Impide que Flutter haga pop de la ruta actual.
        } else {
          // La pila interna está vacía. Estamos en el nivel superior de la navegación actual.
          // Comprueba si este nivel superior es la raíz real de OneDrive.
          if (!_isAtRealRoot) {
            // No estamos en la raíz real (ej. abrimos una subcarpeta desde favoritos).
            // Navegar a la raíz real de OneDrive.
            _goToRoot();
            return false; // Impide que Flutter haga pop de la ruta actual.
          }
          // Estamos en la raíz real de OneDrive. Permite el comportamiento de pop normal.
          return true; 
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_folderName ?? 'OneDrive Explorer'), leading: _folderStack.isNotEmpty ? IconButton(icon: Icon(Icons.arrow_back), onPressed: _goBack) : null, actions: [
          Builder(
            builder: (context) {
              final appState = context.watch<MyAppState>();
              FavoriteFolderIdentifier? currentFolderId = _getCurrentFolderIdentifier();
              bool isCurrentFavorite = false;
              if (currentFolderId != null) {
                isCurrentFavorite = appState.isFavoriteFolder(currentFolderId);
              }

              return currentFolderId != null
                  ? IconButton(
                      icon: Icon(isCurrentFavorite ? Icons.favorite : Icons.favorite_border),
                      tooltip: isCurrentFavorite ? 'Quitar de favoritos' : 'Añadir a favoritos',
                      onPressed: () => appState.toggleFavoriteFolder(currentFolderId),
                    )
                  : SizedBox.shrink(); 
            },          
          ),
          IconButton(
            icon: Icon(Icons.home),
            tooltip: 'Ir a la raíz de OneDrive',
            onPressed: _goToRoot,
          )
        ]),
        body: Column(
          children: [
            if (_isLoadingMetadata)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Center(child: CircularProgressIndicator(semanticsLabel: "Cargando metadatos...",)),
              )
            else if (_metadataError != null)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text("Error al cargar metadatos: $_metadataError", style: TextStyle(color: Colors.red)),
              )
            else if (_folderMetadata != null)
              // Aquí iría el widget de metadatos si decides mostrarlo
              Container(), // Placeholder si no se muestran metadatos directamente
            Expanded(
              child: _itemsStream == null && !_isLoadingMetadata
                  ? Center(child: Text(_metadataError == null ? "Iniciando carga de elementos..." : "No se pudieron cargar elementos."))
                  : StreamBuilder<List<dynamic>>(
                key: ValueKey(_itemsStream), // Fuerza la recreación del estado del StreamBuilder si la instancia del stream cambia
                stream: _itemsStream,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting && (!snapshot.hasData || snapshot.data!.isEmpty) && _itemsStream != null) {
                    return Center(child: CircularProgressIndicator(semanticsLabel: "Cargando elementos..."));
                  } else if (snapshot.hasError) {
                    return Center(child: Text('Error al cargar elementos: ${snapshot.error}'));
                  }

                  final items = snapshot.data ?? [];
                  final bool metadataAvailable = _folderMetadata != null;
                  final int totalExpectedItems = metadataAvailable ? (_folderMetadata!['totalItems'] ?? 0) : 0;
                  
                  // Si no hay elementos y la conexión ha terminado, mostrar "Carpeta vacía"
                  if (items.isEmpty && snapshot.connectionState == ConnectionState.done) {
                     return Center(child: Text('Carpeta vacía'));
                  }

                  if (items.isEmpty && snapshot.connectionState == ConnectionState.active && !_isLoadingMetadata && totalExpectedItems > 0) {
                    return Center(child: CircularProgressIndicator(semanticsLabel: "Cargando elementos..."));
                  } else if (snapshot.hasError) {
                    return Center(child: Text('Error al cargar elementos: ${snapshot.error}'));
                  }

                  final bool activelyLoadingMoreItems = snapshot.connectionState == ConnectionState.active &&
                                                    metadataAvailable &&
                                                    totalExpectedItems > 0 &&
                                                    items.length < totalExpectedItems;

                  return Column(
                    children: [
                      if (activelyLoadingMoreItems)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                          child: Column(
                            children: [
                              Text('Cargados: ${items.length} de $totalExpectedItems'),
                              SizedBox(height: 4),
                              LinearProgressIndicator(
                                value: (totalExpectedItems > 0) ? items.length / totalExpectedItems : 0,
                                backgroundColor: Colors.grey[300],
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: ListView.builder(
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
                                  // Acción para archivos
                                },
                              );
                            } else if (item is OneDriveGallery) {
                              return OneDriveGalleryWidget(gallery: item);
                            } else {
                              return SizedBox.shrink();
                            }
                          }
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
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
      childCount: json['folder']?['childCount'] ?? 0, // Asegúrate que esto es correcto para tus datos
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
      downloadUrl: json['@microsoft.graph.downloadUrl'],
    );
  }
}

abstract class OneDrivePlayableMedia {
  final String id;
  final String name;
  final String downloadUrl;
  final String thumbnailUrl;
  final String thumbnailUrlLarge;
  final DateTime takenDateTime;

  OneDrivePlayableMedia({
    required this.id,
    required this.name,
    required this.downloadUrl,
    required this.thumbnailUrl,
    required this.thumbnailUrlLarge,
    required this.takenDateTime,
  });

}

class OneDriveImage extends OneDrivePlayableMedia {
  OneDriveImage({
    required super.id,
    required super.name,
    required super.downloadUrl,
    required super.thumbnailUrl,
    required super.thumbnailUrlLarge,
    required super.takenDateTime,
  });

  factory OneDriveImage.fromJson(Map<String, dynamic> json) {
    return OneDriveImage(
      id: json['id'],
      name: json['name'],
      downloadUrl: json['@microsoft.graph.downloadUrl'],
      thumbnailUrl: json['thumbnails'] != null && json['thumbnails'].isNotEmpty ? json['thumbnails'][0]['small']['url'] : '',
      thumbnailUrlLarge: json['thumbnails'] != null && json['thumbnails'].isNotEmpty ? json['thumbnails'][0]['large']['url'] : '',
      takenDateTime: DateTime.tryParse(json['photo']?['takenDateTime'] ?? '') ?? DateTime.tryParse(json['createdDateTime'] ?? '') ?? DateTime(1970),
    );
  }
}

class OneDriveVideo extends OneDrivePlayableMedia {
  final int duration; // en milisegundos

  OneDriveVideo({
    required super.id,
    required super.name,
    required super.downloadUrl,
    required super.thumbnailUrl,
    required super.thumbnailUrlLarge,
    required super.takenDateTime,
    required this.duration,
  });

  factory OneDriveVideo.fromJson(Map<String, dynamic> json) {
    return OneDriveVideo(
      id: json['id'],
      name: json['name'],
      downloadUrl: json['@microsoft.graph.downloadUrl'],
      thumbnailUrl: json['thumbnails'] != null && json['thumbnails'].isNotEmpty ? json['thumbnails'][0]['small']['url'] : '',
      thumbnailUrlLarge: json['thumbnails'] != null && json['thumbnails'].isNotEmpty ? json['thumbnails'][0]['large']['url'] : '',
      takenDateTime: DateTime.tryParse(json['video']?['takenDateTime'] ?? '') ?? DateTime.tryParse(json['createdDateTime'] ?? '') ?? DateTime(1970),
      duration: json['video']?['duration'] ?? 0,
    );
  }
}


class OneDriveGallery {
 final Map<String, List<OneDrivePlayableMedia>> mediaByDate;

  OneDriveGallery({required this.mediaByDate});

  factory OneDriveGallery.fromDriveItems(List<Map<String, dynamic>> items) {
    final Map<String, List<OneDrivePlayableMedia>> groupedMedia = {};

    for (var item in items) {
      OneDrivePlayableMedia? mediaItem;
      if (item.containsKey('image')) {
                mediaItem = OneDriveImage.fromJson(item);
      } else if (item.containsKey('video')) {
        mediaItem = OneDriveVideo.fromJson(item);
      }

      if (mediaItem != null) {
        final dateKey = "${mediaItem.takenDateTime.year}-${mediaItem.takenDateTime.month.toString().padLeft(2, '0')}-${mediaItem.takenDateTime.day.toString().padLeft(2, '0')}";
        if (!groupedMedia.containsKey(dateKey)) {
          groupedMedia[dateKey] = [];
        }
        groupedMedia[dateKey]!.add(mediaItem);
      }
    }
    // Ordenar los media items dentro de cada grupo de fechas por su takenDateTime.
    groupedMedia.forEach((key, mediaList) {
      mediaList.sort((a, b) => a.takenDateTime.compareTo(b.takenDateTime)); // Antiguos primero
    });
    return OneDriveGallery(mediaByDate: groupedMedia);
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
  bool _isDateSortAscending = false; // false = descendente (más recientes primero), true = ascendente (más antiguas primero)
  Set<String> _expandedDates = {}; // Almacena las claves de fecha que están completamente expandidas
  static const int _initialImageLimit = 8;

  @override
  Widget build(BuildContext context) {
    // Ordenar los grupos de fechas.
    final sortedDateEntries = widget.gallery.mediaByDate.entries.toList()
      ..sort((a, b) {
        if (_isDateSortAscending) {
          return a.key.compareTo(b.key); // Ascendente
        } else {
          return b.key.compareTo(a.key); // Descendente
        }
      });

    final IconData sortIcon = _isDateSortAscending ? Icons.arrow_downward : Icons.arrow_upward;

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
        TextButton.icon(
          icon: Icon(sortIcon),
          label: Text(_isDateSortAscending ? 'Fechas más antiguas primero' : 'Fechas más recientes primero'),
          onPressed: () {
            setState(() {
              _isDateSortAscending = !_isDateSortAscending;
            });
          },
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).textTheme.bodyLarge?.color, // Usa el color del texto del tema
          ),
        ),
        ...sortedDateEntries.map((entry) { // Usar las entradas ordenadas
          final date = entry.key;
          final mediaItems = entry.value; // Estos media items ya están ordenados por takenDateTime
          final bool isExpanded = _expandedDates.contains(date);
          final List<OneDrivePlayableMedia> displayMedia =
              isExpanded ? mediaItems : (mediaItems.length > _initialImageLimit ? mediaItems.sublist(0, _initialImageLimit) : mediaItems);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16),
                child: Text("$date (${mediaItems.length} ${mediaItems.length == 1 ? 'elemento' : 'elementos'})",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: NeverScrollableScrollPhysics(),
                itemCount: displayMedia.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns.round(),
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemBuilder: (context, index) {
                  final mediaItem = displayMedia[index];
                  return GestureDetector(
                    onTap: () {
                      if (mediaItem is OneDriveImage) {
                        // Filtrar solo imágenes para el visor de imágenes
                        final imagesOnly = mediaItems.whereType<OneDriveImage>().toList();
                        final imageIndex = imagesOnly.indexOf(mediaItem);
                        if (imageIndex != -1) {
                          showImageViewer(context, imagesOnly, imageIndex);
                        }
                      } else if (mediaItem is OneDriveVideo) {
                        // Aquí llamarías a showVideoPlayer
                        showVideoPlayer(context, mediaItem);
                        print('Abrir vídeo: ${mediaItem.name}');
                      }                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          imageUrl: mediaItem.thumbnailUrl.isNotEmpty ? mediaItem.thumbnailUrl : mediaItem.downloadUrl, // Fallback a downloadUrl si no hay thumb
                          placeholder: (context, url) => Center(child: CircularProgressIndicator()),
                          errorWidget: (context, url, error) => Icon(Icons.broken_image),
                          fit: BoxFit.cover,
                        ),
                        if (mediaItem is OneDriveVideo)
                          Center(child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 48)),
                      ],

                    ),
                  );
                },
              ),
              if (!isExpanded && mediaItems.length > _initialImageLimit)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: TextButton(
                      child: Text('Mostrar ${mediaItems.length - _initialImageLimit} más'),
                      onPressed: () {
                        setState(() {
                          _expandedDates.add(date);
                        });
                      },
                    ),
                  ),
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
                    // Asegurarse de que el Hero tag sea único si las imágenes pueden tener el mismo ID en diferentes galerías
                    // o si la misma imagen puede aparecer múltiples veces (aunque no es el caso aquí con OneDriveImage).
                    // Para este contexto, el ID de la imagen debería ser suficiente.
                    final image = images[currentIndex]; // Usar currentIndex para el Hero tag de la imagen actual visible
                    return InteractiveViewer(
                      panEnabled: true,
                      minScale: 1,
                      maxScale: 5,
                      child: Center(
                        child: Hero(
                          tag: image.id,
                          child: CachedNetworkImage( // Usar CachedNetworkImage aquí también
                            imageUrl: image.thumbnailUrlLarge.isNotEmpty ? image.thumbnailUrlLarge : image.downloadUrl,
                            fit: BoxFit.contain,
                            placeholder: (context, url) => Center(child: CircularProgressIndicator()),
                            errorWidget: (context, url, error) => Icon(Icons.error),
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
                        builder: (bsContext) => _buildMediaOptionsSheet(bsContext, images[currentIndex]), // Pasar bsContext
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

Widget _buildMediaOptionsSheet(BuildContext context, OneDrivePlayableMedia mediaItem) {
  return Wrap(
    children: [
      ListTile(
        leading: Icon(Icons.download),
        title: Text('Descargar'),
        onTap: () async {
          Navigator.pop(context); // Cerrar el BottomSheet
          _downloadAndSaveMedia(mediaItem, context); // Usar el context original para ScaffoldMessenger
        },
      ),
      ListTile(
        leading: Icon(Icons.share),
        title: Text('Compartir'),
        onTap: () async {
          Navigator.pop(context); // Cerrar el BottomSheet
          _shareMedia(mediaItem, context); // Usar el context original para ScaffoldMessenger
        },
      ),
    ],
  );
}
/*
Future<File> _downloadImage(OneDriveImage image) async {
  final dir = await getTemporaryDirectory();
  final filePath = '${dir.path}/${Uri.encodeComponent(image.name)}'; // Encode name

  final response = await dio_package.Dio().download(image.downloadUrl, filePath);
  if (response.statusCode == 200) {
    return File(filePath);
  } else {
    throw Exception('Error al descargar imagen: ${response.statusCode}');
  }
}
*/
Future<File> _downloadMediaItem(OneDrivePlayableMedia mediaItem) async {
  final dir = await getTemporaryDirectory();
  // Asegurar que el nombre de archivo sea único o tenga la extensión correcta si es necesario
  final fileName = mediaItem.name.contains('.') ? mediaItem.name : '${mediaItem.name}${mediaItem is OneDriveVideo ? ".mp4" : ".jpg"}';
  final filePath = '${dir.path}/${Uri.encodeComponent(fileName)}';

  final response = await dio_package.Dio().download(mediaItem.downloadUrl, filePath);
  if (response.statusCode == 200) {
    return File(filePath);
  } else {
    throw Exception('Error al descargar media: ${response.statusCode}');
  }
}

Future<void> _shareMedia(OneDrivePlayableMedia mediaItem, BuildContext context) async {
  try {
    final file = await _downloadMediaItem(mediaItem);
    await Share.shareXFiles([XFile(file.path)], text: mediaItem.name);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al compartir: $e')),
      );
    }
  }
}

Future<void> _downloadAndSaveMedia(OneDrivePlayableMedia mediaItem, BuildContext context) async {
  try {
    if (await Permission.storage.request().isGranted || await Permission.photos.request().isGranted) {
      final response = await http.get(Uri.parse(mediaItem.downloadUrl));
      if (response.statusCode == 200) {
        final Uint8List fileBytes = response.bodyBytes;
        if (mediaItem is OneDriveImage) {
          await FlutterImageGallerySaver.saveImage(fileBytes);
        } else if (mediaItem is OneDriveVideo) {
          // Para guardar vídeos, es mejor descargarlos a un archivo temporal primero
          // y luego usar saveFile, ya que saveImage es específico para imágenes.
          final tempDir = await getTemporaryDirectory();
          final tempFile = File('${tempDir.path}/${mediaItem.name}');
          await tempFile.writeAsBytes(fileBytes);
          await FlutterImageGallerySaver.saveFile(tempFile.path);
          await tempFile.delete(); // Limpiar archivo temporal
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${mediaItem is OneDriveImage ? 'Imagen' : 'Vídeo'} guardado en la galería')),
          );
        }
      } else {
        throw 'No se pudo descargar el media (status ${response.statusCode})';
      }
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Permiso denegado para guardar imagen')),
        );
      }
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al guardar: $e')),
      );
    }
  }
}

// Placeholder para el reproductor de vídeo
void showVideoPlayer(BuildContext context, OneDriveVideo video) {
  Navigator.push(context, MaterialPageRoute(builder: (_) => VideoPlayerScreen(video: video)));
}

class VideoPlayerScreen extends StatefulWidget {
  final OneDriveVideo video;

  const VideoPlayerScreen({Key? key, required this.video}) : super(key: key);

  @override
  _VideoPlayerScreenState createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _controller;
  late Future<void> _initializeVideoPlayerFuture;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.video.downloadUrl));
    _initializeVideoPlayerFuture = _controller.initialize().then((_) {
      // Asegura que el primer frame se muestre después de que el vídeo se inicialice
      setState(() {});
    });
    _controller.setLooping(true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.video.name)),
      body: FutureBuilder(
        future: _initializeVideoPlayerFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            return Center(
              child: AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              ),
            );
          } else {
            return Center(child: CircularProgressIndicator());
          }
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _controller.value.isPlaying ? _controller.pause() : _controller.play();
          });
        },
        child: Icon(_controller.value.isPlaying ? Icons.pause : Icons.play_arrow),
      ),
    );
  }
}
