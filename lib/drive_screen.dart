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
  @override
  _OneDriveExplorerState createState() => _OneDriveExplorerState();
}

class _OneDriveExplorerState extends State<OneDriveExplorer> {
  final List<OneDriveFolder> _folderStack = []; // Historial de carpetas
  Stream<List<dynamic>>? _itemsStream;
  late String? _folderName = 'OneDrive Explorer'; // Nombre de la carpeta actual

  @override
  void initState() {
    super.initState();
    _itemsStream = _fetchItemsAsStream(); // Carga del directorio raíz
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
    for (var rawItem in allCombinedRawItems) {
      if (rawItem.containsKey('folder')) {
        processedItems.add(OneDriveFolder.fromJson(rawItem));
      } else if (rawItem.containsKey('file') && !rawItem.containsKey('image')) {
        processedItems.add(OneDriveFile.fromJson(rawItem));
      }
    }

    List<Map<String, dynamic>> imageRawItemsForGallery =
        allCombinedRawItems.where((item) => item.containsKey('image')).toList();
    if (imageRawItemsForGallery.isNotEmpty) {
      OneDriveGallery gallery = OneDriveGallery.fromDriveItems(imageRawItemsForGallery);
      if (gallery.imagesByDate.isNotEmpty) {
        processedItems.add(gallery);
      }
    }

    processedItems.sort((a, b) {
      if (a is OneDriveFolder && !(b is OneDriveFolder)) return -1;
      if (!(a is OneDriveFolder) && b is OneDriveFolder) return 1;
      if (a is OneDriveFile && b is OneDriveFile) return a.name.compareTo(b.name);
      if (a is OneDriveFile && !(b is OneDriveFile) && !(b is OneDriveFolder)) return -1;
      if (!(a is OneDriveFile) && !(a is OneDriveFolder) && b is OneDriveFile) return 1;
      if (a is OneDriveFolder && b is OneDriveFolder) return a.name.compareTo(b.name);
      if (a is OneDriveGallery) return 1;
      if (b is OneDriveGallery) return -1;
      return 0;
    });

    return processedItems;
  }

  Stream<List<dynamic>> _fetchItemsAsStream({String? folderId, String? driveId}) async* {
    final graphService = Provider.of<GraphService>(context, listen: false);
    final token = await graphService.getToken();
    if (token == null) {
      yield [];
      return;
    }
    final headers = {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
    final String graphBaseUrl = "https://graph.microsoft.com/v1.0";

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
      final response = await http.get(Uri.parse(nextLinkChildren), headers: headers);
      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);
        final List<Map<String, dynamic>> currentPageRawItems = List.from(jsonResponse['value']);
        accumulatedRawItemsFromChildren.addAll(currentPageRawItems);
        yield _buildDisplayList(accumulatedRawItemsFromChildren, []);
        nextLinkChildren = jsonResponse['@odata.nextLink'];
      } else if (response.statusCode == 401 && token != null) { // El token podría haber sido invalidado por el refresh
        // El _makeAuthenticatedGetRequest dentro de _fetchItemsAsStream (si se usara allí) manejaría esto.
        // Si no, y el refresh token falla, el usuario será deslogueado.
        print('Error 401 obteniendo items de la carpeta, incluso después de posible refresh. El usuario debería ser deslogueado.');
        throw Exception('Error de autenticación al obtener items de la carpeta.');
      } else {
        print('Error al obtener items de la carpeta: ${response.statusCode} ${response.body}');
        throw Exception('Error al obtener items de la carpeta: ${response.statusCode}');
      }
    }

    if (folderId == null && driveId == null) {
      List<Map<String, dynamic>> accumulatedRawSharedRemoteItems = [];
      String? nextLinkShared = "$graphBaseUrl/me/drive/sharedWithMe?\$expand=thumbnails";

      while (nextLinkShared != null) {
        final response = await http.get(Uri.parse(nextLinkShared), headers: headers);
        if (response.statusCode == 200) {
          final jsonResponse = json.decode(response.body);
          final List<Map<String, dynamic>> currentPageSharedContainers = List.from(jsonResponse['value']);
          for (var container in currentPageSharedContainers) {
            if (container['remoteItem'] is Map<String, dynamic>) {
              accumulatedRawSharedRemoteItems.add(container['remoteItem'] as Map<String, dynamic>);
            }
          }
          yield _buildDisplayList(accumulatedRawItemsFromChildren, accumulatedRawSharedRemoteItems);
          nextLinkShared = jsonResponse['@odata.nextLink'];
        } else if (response.statusCode == 401 && token != null) {
          print('Error 401 obteniendo items compartidos. El usuario debería ser deslogueado.');
          throw Exception('Error de autenticación al obtener items compartidos.');
        } else {
          print("Error al obtener archivos compartidos: ${response.statusCode} ${response.body}");
          nextLinkShared = null;
        }
      }
    }
  }

  void _enterFolder(OneDriveFolder folder) {
    _folderName = folder.name;
    _folderStack.add(folder);
    setState(() {
      _itemsStream = _fetchItemsAsStream(folderId: folder.id, driveId: folder.driveId);
    });
  }

  void _goBack() {
    if (_folderStack.isNotEmpty) {
      _folderStack.removeLast();
      OneDriveFolder? folder = _folderStack.isNotEmpty ? _folderStack.last : null;
      _folderName = folder?.name;
      String? folderId = folder?.id;
      String? driveId = folder?.driveId;
      setState(() {
        _itemsStream = _fetchItemsAsStream(folderId: folderId, driveId: driveId);
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
      body: StreamBuilder<List<dynamic>>(
        stream: _itemsStream,
        builder: (context, snapshot) {
          if ((snapshot.connectionState == ConnectionState.waiting && (!snapshot.hasData || snapshot.data!.isEmpty)) ||
              (snapshot.connectionState == ConnectionState.active && (!snapshot.hasData || snapshot.data!.isEmpty))) {
            return Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text('Error al cargar: ${snapshot.error}'));
          }

          final items = snapshot.data ?? [];

          if (items.isEmpty && snapshot.connectionState == ConnectionState.done) {
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
                    // Acción para archivos
                  },
                );
              } else if (item is OneDriveGallery) {
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
      downloadUrl: json['@microsoft.graph.downloadUrl'],
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
      thumbnailUrl: json['thumbnails'] != null && json['thumbnails'].isNotEmpty ? json['thumbnails'][0]['small']['url'] : '',
      thumbnailUrlLarge: json['thumbnails'] != null && json['thumbnails'].isNotEmpty ? json['thumbnails'][0]['large']['url'] : '',
      takenDateTime: DateTime.tryParse(json['photo']['takenDateTime'] ?? '') ?? DateTime.tryParse(json['createdDateTime'] ?? '') ?? DateTime(1970),
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
        final dateKey = "${image.takenDateTime.year}-${image.takenDateTime.month.toString().padLeft(2, '0')}-${image.takenDateTime.day.toString().padLeft(2, '0')}";
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
                child: Text(date, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
                        builder: (bsContext) => _buildImageOptionsSheet(bsContext, images[currentIndex]), // Pasar bsContext
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
          Navigator.pop(context); // Cerrar el BottomSheet
          _downloadAndSaveImage(image, context); // Usar el context original para ScaffoldMessenger
        },
      ),
      ListTile(
        leading: Icon(Icons.share),
        title: Text('Compartir'),
        onTap: () async {
          Navigator.pop(context); // Cerrar el BottomSheet
          _shareImage(image, context); // Usar el context original para ScaffoldMessenger
        },
      ),
    ],
  );
}

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

Future<void> _shareImage(OneDriveImage image, BuildContext context) async {
  try {
    final file = await _downloadImage(image);
    await Share.shareXFiles([XFile(file.path)], text: image.name);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al compartir: $e')),
      );
    }
  }
}

Future<void> _downloadAndSaveImage(OneDriveImage image, BuildContext context) async {
  try {
    if (await Permission.storage.request().isGranted || await Permission.photos.request().isGranted) {
      final response = await http.get(Uri.parse(image.downloadUrl));
      if (response.statusCode == 200) {
        final Uint8List imageBytes = response.bodyBytes;
        await FlutterImageGallerySaver.saveImage(imageBytes); // Añadir nombre
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imagen guardada en la galería')),
          );
        }
      } else {
        throw 'No se pudo descargar la imagen (status ${response.statusCode})';
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