import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'main.dart'; // Para acceder a MyAppState

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