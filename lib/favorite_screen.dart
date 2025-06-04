import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'main.dart'; // Para acceder a MyAppState y FavoriteFolderIdentifier

class FavoriteScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    var appState = context.watch<MyAppState>();

    if (appState.favoriteFolders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Text(
            'No tienes carpetas favoritas todavía. \nPuedes añadir carpetas a favoritos desde el explorador de OneDrive.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );
    }

    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text('Tienes ${appState.favoriteFolders.length} carpetas favoritas:',
              style: Theme.of(context).textTheme.titleLarge),
        ),
        for (var favFolder in appState.favoriteFolders)
          ListTile(
            leading: Icon(Icons.folder_special, color: Theme.of(context).colorScheme.primary),
            title: Text(favFolder.name),
            subtitle: Text(favFolder.driveId == null ? 'Drive personal' : 'Drive: ${favFolder.driveId ?? "Desconocido"}'),
            trailing: IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.redAccent),
              tooltip: 'Quitar de favoritos',
              onPressed: () => appState.removeFavoriteFolder(favFolder),
            ),
            onTap: () {
              // Navegar a OneDriveExplorer y abrir esta carpeta
              appState.openFolderFromFavorites(favFolder);
            },
          ),
      ],
    );
  }
}