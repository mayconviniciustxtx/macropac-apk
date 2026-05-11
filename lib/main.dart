import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String baseApi = 'https://mega4tech.com.br/macropac_rastreamento/api/';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MacropacApp());
}

class MacropacApp extends StatelessWidget {
  const MacropacApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Macropac Rastreamento',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF087B70)),
        useMaterial3: true,
      ),
      home: const AppGate(),
    );
  }
}

class AppGate extends StatefulWidget {
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

class _AppGateState extends State<AppGate> {
  String? token;
  Map<String, dynamic>? motorista;
  Map<String, dynamic>? caminhao;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    carregarSessao();
  }

  Future<void> carregarSessao() async {
    final prefs = await SharedPreferences.getInstance();
    final t = prefs.getString('token');
    final m = prefs.getString('motorista');
    final c = prefs.getString('caminhao');

    if (mounted) {
      setState(() {
        token = t;
        motorista = m == null ? null : jsonDecode(m);
        caminhao = c == null ? null : jsonDecode(c);
        loading = false;
      });
    }
  }

  Future<void> onLogin(String t, Map<String, dynamic> m, Map<String, dynamic> c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', t);
    await prefs.setString('motorista', jsonEncode(m));
    await prefs.setString('caminhao', jsonEncode(c));
    if (mounted) {
      setState(() {
        token = t;
        motorista = m;
        caminhao = c;
      });
    }
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (mounted) {
      setState(() {
        token = null;
        motorista = null;
        caminhao = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (token == null || motorista == null || caminhao == null) {
      return LoginPage(onLogin: onLogin);
    }

    return RastreamentoPage(
      token: token!,
      motorista: motorista!,
      caminhao: caminhao!,
      onLogout: logout,
    );
  }
}

class LoginPage extends StatefulWidget {
  final Future<void> Function(String token, Map<String, dynamic> motorista, Map<String, dynamic> caminhao) onLogin;
  const LoginPage({super.key, required this.onLogin});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final loginController = TextEditingController(text: 'motorista.teste');
  final senhaController = TextEditingController(text: '123456');
  bool entrando = false;
  String status = 'Informe login e senha.';

  Future<void> entrar() async {
    setState(() {
      entrando = true;
      status = 'Entrando...';
    });

    try {
      final resp = await http.post(
        Uri.parse('${baseApi}app_login_motorista.php'),
        body: {
          'login': loginController.text.trim(),
          'senha': senhaController.text.trim(),
          'device_id': 'android_${DateTime.now().millisecondsSinceEpoch}',
          'device_name': 'Android',
        },
      ).timeout(const Duration(seconds: 20));

      final json = jsonDecode(resp.body);
      if (json['success'] == true) {
        await widget.onLogin(
          json['token'].toString(),
          Map<String, dynamic>.from(json['motorista']),
          Map<String, dynamic>.from(json['caminhao']),
        );
      } else {
        setState(() => status = json['message']?.toString() ?? 'Erro no login.');
      }
    } catch (e) {
      setState(() => status = 'Erro ao conectar: $e');
    } finally {
      if (mounted) setState(() => entrando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Macropac Rastreamento')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Card(
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('MACROPAC', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 24),
                  TextField(controller: loginController, decoration: const InputDecoration(labelText: 'Login')),
                  const SizedBox(height: 12),
                  TextField(controller: senhaController, obscureText: true, decoration: const InputDecoration(labelText: 'Senha')),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: entrando ? null : entrar, child: Text(entrando ? 'Entrando...' : 'Entrar')),
                  const SizedBox(height: 16),
                  Text(status),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RastreamentoPage extends StatefulWidget {
  final String token;
  final Map<String, dynamic> motorista;
  final Map<String, dynamic> caminhao;
  final VoidCallback onLogout;

  const RastreamentoPage({
    super.key,
    required this.token,
    required this.motorista,
    required this.caminhao,
    required this.onLogout,
  });

  @override
  State<RastreamentoPage> createState() => _RastreamentoPageState();
}

class _RastreamentoPageState extends State<RastreamentoPage> {
  Timer? timer;
  String status = 'Iniciando rastreamento automático...';
  bool enviando = false;
  int? rotaId;
  final Battery battery = Battery();

  @override
  void initState() {
    super.initState();
    iniciarAutomatico();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  String motoristaNome() => widget.motorista['nome']?.toString() ?? '-';
  String caminhaoTexto() {
    final placa = widget.caminhao['placa']?.toString() ?? '-';
    final desc = widget.caminhao['descricao']?.toString() ?? '';
    return desc.isEmpty ? placa : '$placa - $desc';
  }

  Future<void> iniciarAutomatico() async {
    await solicitarPermissao();
    await iniciarRota();
    await enviarLocalizacao();
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 15), (_) => enviarLocalizacao());
  }

  Future<void> solicitarPermissao() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => status = 'GPS desligado. Ative a localização do aparelho.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      setState(() => status = 'Permissão de localização negada.');
    }
  }

  Future<void> iniciarRota() async {
    try {
      final resp = await http.post(
        Uri.parse('${baseApi}app_iniciar_rota.php'),
        body: {'token': widget.token},
      ).timeout(const Duration(seconds: 20));

      final json = jsonDecode(resp.body);
      if (json['success'] == true) {
        rotaId = int.tryParse(json['rota_id'].toString());
        setState(() => status = 'Rastreamento iniciado. Enviando localização...');
      } else {
        setState(() => status = json['message']?.toString() ?? 'Erro ao iniciar rota.');
      }
    } catch (e) {
      setState(() => status = 'Erro ao iniciar rota: $e');
    }
  }

  Future<void> enviarLocalizacao() async {
    if (enviando) return;
    enviando = true;

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );
      final bateria = await battery.batteryLevel;

      final resp = await http.post(
        Uri.parse('${baseApi}app_salvar_localizacao.php'),
        body: {
          'token': widget.token,
          'latitude': pos.latitude.toString(),
          'longitude': pos.longitude.toString(),
          'velocidade': (pos.speed < 0 ? 0 : pos.speed).toStringAsFixed(2),
          'precisao': pos.accuracy.toStringAsFixed(2),
          'bateria': bateria.toString(),
        },
      ).timeout(const Duration(seconds: 20));

      final json = jsonDecode(resp.body);
      if (json['success'] == true) {
        setState(() {
          status = 'Localização enviada em ${DateTime.now().toString().substring(11, 19)}\n'
              'Lat: ${pos.latitude}\nLng: ${pos.longitude}\nPrecisão: ${pos.accuracy.toStringAsFixed(2)}m\nBateria: $bateria%';
        });
      } else {
        setState(() => status = json['message']?.toString() ?? 'Erro ao salvar localização.');
      }
    } catch (e) {
      setState(() => status = 'Erro ao enviar localização: $e');
    } finally {
      enviando = false;
    }
  }

  Future<void> emergencia() async {
    setState(() => status = 'Enviando pedido de emergência...');
    try {
      Position? pos;
      try {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        );
      } catch (_) {}
      final bateria = await battery.batteryLevel;

      final resp = await http.post(
        Uri.parse('${baseApi}app_emergencia.php'),
        body: {
          'token': widget.token,
          'latitude': pos?.latitude.toString() ?? '',
          'longitude': pos?.longitude.toString() ?? '',
          'bateria': bateria.toString(),
          'mensagem': 'Motorista solicitou ajuda pelo aplicativo',
        },
      ).timeout(const Duration(seconds: 20));

      final json = jsonDecode(resp.body);
      if (json['success'] == true) {
        setState(() => status = 'Emergência enviada para a central. Aguarde contato.');
      } else {
        setState(() => status = json['message']?.toString() ?? 'Erro ao enviar emergência.');
      }
    } catch (e) {
      setState(() => status = 'Erro ao enviar emergência: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Macropac Rastreamento'),
        actions: [IconButton(onPressed: widget.onLogout, icon: const Icon(Icons.logout))],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Card(
            elevation: 8,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('MACROPAC', style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 24),
                  Text('Motorista: ${motoristaNome()}', style: const TextStyle(fontSize: 20)),
                  const SizedBox(height: 8),
                  Text('Caminhão: ${caminhaoTexto()}', style: const TextStyle(fontSize: 20)),
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Text(status, style: const TextStyle(fontSize: 18)),
                  ),
                  const SizedBox(height: 22),
                  FilledButton.icon(
                    onPressed: emergencia,
                    icon: const Icon(Icons.warning_amber_rounded),
                    label: const Text('EMERGÊNCIA / PEDIR AJUDA'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
