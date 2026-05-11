import 'dart:async';
import 'dart:convert';

import 'package:battery_plus/battery_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String apiBase = 'https://mega4tech.com.br/macropac_rastreamento/api/';
const Duration envioIntervalo = Duration(seconds: 30);

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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}

class ApiClient {
  static Future<Map<String, dynamic>> post(String endpoint, Map<String, String> data) async {
    final uri = Uri.parse('$apiBase$endpoint');
    final response = await http.post(uri, body: data).timeout(const Duration(seconds: 20));

    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return {
        'success': false,
        'message': 'Resposta inválida do servidor',
        'raw': response.body,
      };
    }
  }
}

Future<String> getDeviceId() async {
  final info = DeviceInfoPlugin();
  try {
    final android = await info.androidInfo;
    return android.id;
  } catch (_) {
    return DateTime.now().millisecondsSinceEpoch.toString();
  }
}

Future<String> getDeviceName() async {
  final info = DeviceInfoPlugin();
  try {
    final android = await info.androidInfo;
    return '${android.manufacturer} ${android.model}';
  } catch (_) {
    return 'Android';
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final loginController = TextEditingController(text: 'motorista.teste');
  final senhaController = TextEditingController(text: '123456');
  bool carregando = false;
  String status = 'Informe login e senha.';

  @override
  void initState() {
    super.initState();
    _verificarSessao();
  }

  Future<void> _verificarSessao() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token != null && token.isNotEmpty && mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const RastreamentoPage()),
      );
    }
  }

  Future<void> entrar() async {
    setState(() {
      carregando = true;
      status = 'Entrando...';
    });

    final deviceId = await getDeviceId();
    final deviceName = await getDeviceName();

    final resp = await ApiClient.post('app_login_motorista.php', {
      'login': loginController.text.trim(),
      'senha': senhaController.text.trim(),
      'device_id': deviceId,
      'device_name': deviceName,
    });

    setState(() => carregando = false);

    if (resp['success'] == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', resp['token']?.toString() ?? '');
      await prefs.setString('motorista_nome', resp['motorista']?.toString() ?? '');
      await prefs.setString('caminhao_placa', resp['caminhao']?.toString() ?? '');

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const RastreamentoPage()),
      );
    } else {
      setState(() => status = resp['message']?.toString() ?? 'Erro ao fazer login.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FB),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('MACROPAC', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Rastreamento de Frota', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: loginController,
                    decoration: const InputDecoration(labelText: 'Login do motorista', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: senhaController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Senha', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: carregando ? null : entrar,
                    child: Text(carregando ? 'Entrando...' : 'Entrar'),
                  ),
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
  const RastreamentoPage({super.key});

  @override
  State<RastreamentoPage> createState() => _RastreamentoPageState();
}

class _RastreamentoPageState extends State<RastreamentoPage> {
  Timer? timer;
  bool rastreando = false;
  bool enviando = false;
  String token = '';
  String motorista = '';
  String caminhao = '';
  String status = 'Pronto para iniciar.';
  int? rotaId;

  @override
  void initState() {
    super.initState();
    _carregarSessao();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _carregarSessao() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      token = prefs.getString('token') ?? '';
      motorista = prefs.getString('motorista_nome') ?? '';
      caminhao = prefs.getString('caminhao_placa') ?? '';
    });
  }

  Future<bool> _garantirPermissaoLocalizacao() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => status = 'GPS desativado. Ative a localização do aparelho.');
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      setState(() => status = 'Permissão de localização negada.');
      return false;
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() => status = 'Permissão negada permanentemente. Libere nas configurações do Android.');
      return false;
    }

    return true;
  }

  Future<void> iniciar() async {
    final permissaoOk = await _garantirPermissaoLocalizacao();
    if (!permissaoOk) return;

    setState(() {
      enviando = true;
      status = 'Iniciando rota...';
    });

    final resp = await ApiClient.post('app_iniciar_rota.php', {
      'token': token,
    });

    if (resp['success'] == true) {
      rotaId = int.tryParse(resp['rota_id']?.toString() ?? '');
      rastreando = true;
      await WakelockPlus.enable();
      setState(() => status = 'Rastreamento iniciado. Enviando localização...');
      await enviarLocalizacao();
      timer?.cancel();
      timer = Timer.periodic(envioIntervalo, (_) => enviarLocalizacao());
    } else {
      setState(() => status = resp['message']?.toString() ?? 'Erro ao iniciar rota.');
    }

    setState(() => enviando = false);
  }

  Future<void> enviarLocalizacao() async {
    if (!rastreando || enviando) return;

    setState(() {
      enviando = true;
      status = 'Capturando GPS...';
    });

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );

      final battery = Battery();
      int bateria = 0;
      try {
        bateria = await battery.batteryLevel;
      } catch (_) {}

      final resp = await ApiClient.post('app_salvar_localizacao.php', {
        'token': token,
        'latitude': pos.latitude.toString(),
        'longitude': pos.longitude.toString(),
        'velocidade': pos.speed.isNaN ? '' : pos.speed.toString(),
        'precisao': pos.accuracy.isNaN ? '' : pos.accuracy.toString(),
        'bateria': bateria > 0 ? bateria.toString() : '',
      });

      if (resp['success'] == true) {
        setState(() {
          status = 'Localização enviada com sucesso.\n'
              'Lat: ${pos.latitude}\n'
              'Lng: ${pos.longitude}\n'
              'Precisão: ${pos.accuracy.toStringAsFixed(1)}m\n'
              'Bateria: ${bateria > 0 ? bateria : '-'}%\n'
              'Próximo envio em 30 segundos.';
        });
      } else {
        setState(() => status = resp['message']?.toString() ?? 'Erro ao salvar localização.');
      }
    } catch (e) {
      setState(() => status = 'Erro ao capturar/enviar GPS: $e');
    }

    setState(() => enviando = false);
  }

  Future<void> parar() async {
    timer?.cancel();
    timer = null;
    rastreando = false;
    await WakelockPlus.disable();

    final resp = await ApiClient.post('app_parar_rota.php', {
      'token': token,
    });

    setState(() => status = resp['message']?.toString() ?? 'Rastreamento parado.');
  }

  Future<void> sair() async {
    timer?.cancel();
    await WakelockPlus.disable();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FB),
      appBar: AppBar(
        title: const Text('Macropac Rastreamento'),
        actions: [
          IconButton(onPressed: sair, icon: const Icon(Icons.logout)),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Card(
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('MACROPAC', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text('Motorista: ${motorista.isEmpty ? '-' : motorista}', style: const TextStyle(fontSize: 18)),
                Text('Caminhão: ${caminhao.isEmpty ? '-' : caminhao}', style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: rastreando ? null : iniciar,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Iniciar rastreamento'),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: rastreando ? parar : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Parar rastreamento'),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(status, style: const TextStyle(fontSize: 16)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
