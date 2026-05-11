import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String apiBase = 'https://mega4tech.com.br/macropac_rastreamento/api/';
const Duration intervaloEnvio = Duration(seconds: 15);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const MacropacApp());
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'macropac_rastreamento',
      initialNotificationTitle: 'Macropac Rastreamento',
      initialNotificationContent: 'Rastreamento ativo',
      foregroundServiceNotificationId: 1001,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: 'Macropac Rastreamento ativo',
      content: 'Enviando localização em segundo plano',
    );
  }

  Future<void> enviarNoServico() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');

    if (token == null || token.isEmpty) return;

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );

      final bateria = await Battery().batteryLevel;

      final r = await enviarLocalizacaoApi(
        token: token,
        latitude: pos.latitude,
        longitude: pos.longitude,
        precisao: pos.accuracy,
        velocidade: pos.speed.isNaN ? null : pos.speed,
        bateria: bateria,
      );

      if (service is AndroidServiceInstance) {
        final hora = DateTime.now().toString().substring(11, 19);
        service.setForegroundNotificationInfo(
          title: 'Macropac Rastreamento ativo',
          content: r['success'] == true ? 'Último envio: $hora' : 'Falha ao enviar. Tentando novamente...',
        );
      }
    } catch (_) {
      if (service is AndroidServiceInstance) {
        service.setForegroundNotificationInfo(
          title: 'Macropac Rastreamento ativo',
          content: 'Aguardando GPS/internet...',
        );
      }
    }
  }

  await enviarNoServico();
  Timer.periodic(intervaloEnvio, (_) => enviarNoServico());
}

Future<Map<String, dynamic>> postApi(String endpoint, Map<String, String> body) async {
  final uri = Uri.parse('$apiBase$endpoint');
  final response = await http.post(uri, body: body).timeout(const Duration(seconds: 25));

  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'success': false, 'message': 'Retorno inválido da API.'};
  } catch (_) {
    return {'success': false, 'message': 'Erro no retorno da API: ${response.body}'};
  }
}

Future<Map<String, dynamic>> enviarLocalizacaoApi({
  required String token,
  required double latitude,
  required double longitude,
  double? precisao,
  double? velocidade,
  int? bateria,
}) async {
  return postApi('app_salvar_localizacao.php', {
    'token': token,
    'latitude': latitude.toString(),
    'longitude': longitude.toString(),
    'precisao': precisao?.toString() ?? '',
    'velocidade': velocidade?.toString() ?? '',
    'bateria': bateria?.toString() ?? '',
    'origem': 'apk',
  });
}

Future<Map<String, dynamic>> enviarEmergenciaApi({
  required String token,
  double? latitude,
  double? longitude,
  double? precisao,
  int? bateria,
}) async {
  return postApi('app_emergencia.php', {
    'token': token,
    'latitude': latitude?.toString() ?? '',
    'longitude': longitude?.toString() ?? '',
    'precisao': precisao?.toString() ?? '',
    'bateria': bateria?.toString() ?? '',
    'mensagem': 'Motorista solicitou ajuda pelo aplicativo',
  });
}

class MacropacApp extends StatelessWidget {
  const MacropacApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Macropac Rastreamento',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
        useMaterial3: true,
      ),
      home: const LoginGate(),
    );
  }
}

class LoginGate extends StatefulWidget {
  const LoginGate({super.key});

  @override
  State<LoginGate> createState() => _LoginGateState();
}

class _LoginGateState extends State<LoginGate> {
  bool carregando = true;
  String? token;
  Map<String, dynamic>? motorista;
  Map<String, dynamic>? caminhao;

  @override
  void initState() {
    super.initState();
    carregarSessao();
  }

  Future<void> carregarSessao() async {
    final prefs = await SharedPreferences.getInstance();
    final salvoToken = prefs.getString('token');
    final salvoMotorista = prefs.getString('motorista');
    final salvoCaminhao = prefs.getString('caminhao');

    if (salvoToken != null && salvoToken.isNotEmpty) {
      token = salvoToken;
      motorista = salvoMotorista != null ? jsonDecode(salvoMotorista) : null;
      caminhao = salvoCaminhao != null ? jsonDecode(salvoCaminhao) : null;
    }

    setState(() => carregando = false);
  }

  @override
  Widget build(BuildContext context) {
    if (carregando) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (token == null || token!.isEmpty) {
      return LoginPage(onLogin: carregarSessao);
    }

    return HomePage(token: token!, motorista: motorista, caminhao: caminhao);
  }
}

class LoginPage extends StatefulWidget {
  final Future<void> Function() onLogin;
  const LoginPage({super.key, required this.onLogin});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final loginCtrl = TextEditingController(text: 'motorista.teste');
  final senhaCtrl = TextEditingController(text: '123456');
  bool entrando = false;
  String status = 'Informe login e senha.';

  Future<void> entrar() async {
    setState(() {
      entrando = true;
      status = 'Entrando...';
    });

    try {
      final r = await postApi('app_login_motorista.php', {
        'login': loginCtrl.text.trim(),
        'senha': senhaCtrl.text.trim(),
        'device_id': 'android-${DateTime.now().millisecondsSinceEpoch}',
        'device_name': 'Android',
      });

      if (r['success'] != true) {
        setState(() {
          entrando = false;
          status = r['message']?.toString() ?? 'Erro ao entrar.';
        });
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', r['token'].toString());
      await prefs.setString('motorista', jsonEncode(r['motorista'] ?? {}));
      await prefs.setString('caminhao', jsonEncode(r['caminhao'] ?? {}));

      await widget.onLogin();
    } catch (e) {
      setState(() {
        entrando = false;
        status = 'Erro de conexão: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(title: const Text('Macropac Rastreamento')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('MACROPAC', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 22),
                  TextField(controller: loginCtrl, decoration: const InputDecoration(labelText: 'Login')),
                  const SizedBox(height: 12),
                  TextField(controller: senhaCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Senha')),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: entrando ? null : entrar,
                      child: Text(entrando ? 'Entrando...' : 'Entrar'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: Text(status),
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

class HomePage extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? motorista;
  final Map<String, dynamic>? caminhao;

  const HomePage({super.key, required this.token, this.motorista, this.caminhao});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String status = 'Preparando rastreamento automático...';
  String ultimaHora = '-';
  Timer? timerTela;
  bool iniciado = false;
  bool enviandoEmergencia = false;

  String get motoristaNome => (widget.motorista?['nome'] ?? 'Motorista').toString();
  String get caminhaoPlaca => (widget.caminhao?['placa'] ?? 'Caminhão').toString();
  String get caminhaoDescricao => (widget.caminhao?['descricao'] ?? '').toString();

  @override
  void initState() {
    super.initState();
    iniciarAutomatico();
  }

  @override
  void dispose() {
    timerTela?.cancel();
    super.dispose();
  }

  Future<void> iniciarAutomatico() async {
    setState(() => status = 'Solicitando permissões...');

    final okPermissao = await solicitarPermissoes();
    if (!okPermissao) {
      setState(() => status = 'Permissão de localização negada. Libere nas configurações do Android.');
      return;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => status = 'GPS desligado. Ative a localização do aparelho.');
      return;
    }

    final r = await postApi('app_iniciar_rota.php', {'token': widget.token});
    if (r['success'] != true) {
      setState(() => status = r['message']?.toString() ?? 'Erro ao iniciar rota.');
      return;
    }

    final service = FlutterBackgroundService();
    await service.startService();

    iniciado = true;
    setState(() => status = 'Rastreamento automático ativo. Enviando localização a cada 15 segundos.');

    await enviarUmaLocalizacao();
    timerTela?.cancel();
    timerTela = Timer.periodic(intervaloEnvio, (_) => enviarUmaLocalizacao());
  }

  Future<bool> solicitarPermissoes() async {
    await Permission.notification.request();

    final location = await Permission.location.request();
    if (!location.isGranted) return false;

    await Permission.locationAlways.request();
    return true;
  }

  Future<Position?> pegarPosicaoAtual() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> enviarUmaLocalizacao() async {
    if (!iniciado) return;

    try {
      final pos = await pegarPosicaoAtual();
      if (pos == null) {
        setState(() => status = 'Rastreamento ativo, aguardando sinal de GPS...');
        return;
      }

      final bateria = await Battery().batteryLevel;

      final r = await enviarLocalizacaoApi(
        token: widget.token,
        latitude: pos.latitude,
        longitude: pos.longitude,
        precisao: pos.accuracy,
        velocidade: pos.speed.isNaN ? null : pos.speed,
        bateria: bateria,
      );

      if (r['success'] == true) {
        final hora = DateTime.now().toString().substring(11, 19);
        setState(() {
          ultimaHora = hora;
          status = 'Localização enviada com sucesso.\n'
              'Último envio: $hora\n'
              'Latitude: ${pos.latitude}\n'
              'Longitude: ${pos.longitude}\n'
              'Precisão: ${pos.accuracy.toStringAsFixed(1)}m\n'
              'Bateria: $bateria%';
        });
      } else {
        setState(() => status = r['message']?.toString() ?? 'Erro ao enviar localização.');
      }
    } catch (e) {
      setState(() => status = 'Rastreamento ativo, aguardando GPS/internet.\n$e');
    }
  }

  Future<void> enviarEmergencia() async {
    if (enviandoEmergencia) return;

    setState(() {
      enviandoEmergencia = true;
      status = 'Enviando pedido de emergência...';
    });

    try {
      final pos = await pegarPosicaoAtual();
      final bateria = await Battery().batteryLevel;

      final r = await enviarEmergenciaApi(
        token: widget.token,
        latitude: pos?.latitude,
        longitude: pos?.longitude,
        precisao: pos?.accuracy,
        bateria: bateria,
      );

      if (r['success'] == true) {
        if (pos != null) {
          await enviarLocalizacaoApi(
            token: widget.token,
            latitude: pos.latitude,
            longitude: pos.longitude,
            precisao: pos.accuracy,
            velocidade: pos.speed.isNaN ? null : pos.speed,
            bateria: bateria,
          );
        }

        setState(() {
          ultimaHora = DateTime.now().toString().substring(11, 19);
          status = 'EMERGÊNCIA ENVIADA COM SUCESSO.\nA central foi notificada.\nHorário: $ultimaHora';
        });
      } else {
        setState(() => status = r['message']?.toString() ?? 'Erro ao enviar emergência.');
      }
    } catch (e) {
      setState(() => status = 'Erro ao enviar emergência: $e');
    } finally {
      setState(() => enviandoEmergencia = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(title: const Text('Macropac Rastreamento')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: Padding(
              padding: const EdgeInsets.all(26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('MACROPAC', style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 28),
                  Text('Motorista: $motoristaNome', style: const TextStyle(fontSize: 21)),
                  const SizedBox(height: 10),
                  Text('Caminhão: $caminhaoPlaca', style: const TextStyle(fontSize: 21)),
                  if (caminhaoDescricao.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(caminhaoDescricao, style: const TextStyle(fontSize: 18, color: Colors.black54)),
                  ],
                  const SizedBox(height: 26),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0F2F1),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.gps_fixed, color: Color(0xFF0F766E)),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Rastreamento automático ativo',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F766E)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: enviandoEmergencia ? null : enviarEmergencia,
                      icon: const Icon(Icons.warning_amber_rounded),
                      label: Text(enviandoEmergencia ? 'Enviando emergência...' : 'EMERGÊNCIA / PEDIR AJUDA'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFB91C1C),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.black12),
                    ),
                    child: Text(status, style: const TextStyle(fontSize: 17)),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Último envio: $ultimaHora. Mantenha GPS, internet e permissão de localização sempre ativa.',
                    style: const TextStyle(color: Colors.black54),
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
