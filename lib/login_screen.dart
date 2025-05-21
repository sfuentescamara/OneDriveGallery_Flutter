import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'service.dart'; // Importa el archivo de servicios

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
                  if (_isLoading) CircularProgressIndicator(),

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
                  ElevatedButton(
                    onPressed: () async {
                      if (_isLoading) return;

                      setState(() {
                        _isLoading = true;
                      });

                      // 1. Realizar el logout completo (navegador y local)
                      await authService.logoutAndAllowAccountChange(context);

                      // 2. Iniciar un nuevo flujo de login forzando la selección de cuenta
                      String? token = await graphService.requestToken(promptSelectAccount: true);

                      if (token != null) {
                        await authService.saveToken(token);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Sesión iniciada. Por favor, verifique la cuenta.")),
                          );
                        }
                      } else {
                        // El usuario pudo haber cancelado la selección de cuenta o hubo un error
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text("Proceso de cambio de cuenta cancelado o fallido.")),
                          );
                        }
                      }

                      if (mounted) {
                        setState(() {
                          _isLoading = false;
                        });
                      }
                    },
                    child: Text('Cambiar de cuenta'),
                  ),
                ]);
          },
        ),
      ),
    );
  }
}