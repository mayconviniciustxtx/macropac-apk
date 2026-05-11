import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

const String apiBase = 'https://mega4tech.com.br/macropac_rastreamento/api';
const int intervaloSegundos = 15;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await inicializarServicoSegundoPlano();
  runApp(const MacropacApp());
}

Future<void> inicializarServicoSegundoPlano() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartBackground,
      autoStart: false,
      isForegroundMode: true,
      autoStartOnBoot: true,
      notificationChannelId: 'macropac_rastreamento',
      initialNotificationTitle: 'Macropac Rastreamento',
      initialNotificationContent: 'Rastreamento em execução',
      foregroundServiceNotificationId: 1999,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStartBackground,
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
void onStartBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: 'Macropac Rastreamento',
      content: 'Enviando localização em segundo plano',
    );
  }
  Timer? timer;
  Future<void> tick() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token') ?? '';
      if (token.isEmpty) {
        if (service is AndroidServiceInstance) {
          service.setForegroundNotificationInfo(
            title: 'Macropac Rastreamento',
            content: 'Aguardando login do motorista',
          );
        }
        return;
      }
      final ok = await enviarLocalizacaoBackground(token);
      if (service is AndroidServiceInstance) {
        final agora = DateTime.now();
        service.setForegroundNotificationInfo(
          title: 'Macropac Rastreamento',
          content: ok
              ? 'GPS enviado ${agora.hour.toString().padLeft(2, '0')}:${agora.minute.toString().padLeft(2, '0')}:${agora.second.toString().padLeft(2, '0')}'
              : 'Tentando enviar localização...',
        );
      }
    } catch (_) {}
  }
  service.on('forcar_envio').listen((event) async => tick());
  service.on('stop').listen((event) {
    timer?.cancel();
    service.stopSelf();
  });
  await tick();
  timer = Timer.periodic(const Duration(seconds: intervaloSegundos), (_) async => tick());
}

Future<bool> enviarLocalizacaoBackground(String token) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    LocationPermission permissao = await Geolocator.checkPermission();
    if (permissao == LocationPermission.denied) {
      permissao = await Geolocator.requestPermission();
    }
    if (permissao == LocationPermission.denied || permissao == LocationPermission.deniedForever) return false;
    final pos = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 20),
    );
    int bat = -1;
    try { bat = await Battery().batteryLevel; } catch (_) {}
    final resp = await http.post(
      Uri.parse('$apiBase/app_salvar_localizacao.php'),
      body: {
        'token': token,
        'latitude': pos.latitude.toString(),
        'longitude': pos.longitude.toString(),
        'velocidade': pos.speed.isNaN ? '' : pos.speed.toString(),
        'precisao': pos.accuracy.isNaN ? '' : pos.accuracy.toString(),
        'bateria': bat >= 0 ? bat.toString() : '',
        'origem': 'apk_background',
      },
    ).timeout(const Duration(seconds: 25));
    return resp.statusCode >= 200 && resp.statusCode < 300;
  } catch (_) {
    return false;
  }
}

class MacropacApp extends StatelessWidget {
  const MacropacApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Macropac Rastreamento',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0F766E), useMaterial3: true),
      home: const TelaInicial(),
    );
  }
}

class TelaInicial extends StatefulWidget {
  const TelaInicial({super.key});
  @override
  State<TelaInicial> createState() => _TelaInicialState();
}

class _TelaInicialState extends State<TelaInicial> {
  final loginCtrl = TextEditingController(text: 'motorista.teste');
  final senhaCtrl = TextEditingController(text: '123456');
  bool carregando = true;
  bool entrando = false;
  bool logado = false;
  String status = 'Inicializando...';
  String motorista = '';
  String caminhao = '';
  String ultimaAtualizacao = '-';
  String ultimaLatitude = '-';
  String ultimaLongitude = '-';
  String ultimaPrecisao = '-';
  String bateria = '-';
  Timer? timerTela;

  @override
  void initState() {
    super.initState();
    carregarSessao();
  }

  @override
  void dispose() {
    timerTela?.cancel();
    loginCtrl.dispose();
    senhaCtrl.dispose();
    super.dispose();
  }

  Future<void> carregarSessao() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token') ?? '';
    if (token.isNotEmpty) {
      setState(() {
        logado = true;
        carregando = false;
        motorista = prefs.getString('motorista_nome') ?? 'Motorista';
        caminhao = prefs.getString('caminhao_placa') ?? '-';
        status = 'Rastreamento automático ativo.';
      });
      await prepararPermissoes();
      await iniciarRastreamentoAutomatico();
      iniciarTimerTela();
    } else {
      setState(() {
        carregando = false;
        status = 'Informe login e senha.';
      });
    }
  }

  Future<void> prepararPermissoes() async {
    setState(() => status = 'Verificando permissões...');
    final gpsLigado = await Geolocator.isLocationServiceEnabled();
    if (!gpsLigado) {
      setState(() => status = 'GPS desligado. Ative a localização do celular.');
      await Geolocator.openLocationSettings();
      return;
    }
    LocationPermission permissao = await Geolocator.checkPermission();
    if (permissao == LocationPermission.denied) {
      permissao = await Geolocator.requestPermission();
    }
    if (permissao == LocationPermission.denied || permissao == LocationPermission.deniedForever) {
      setState(() => status = 'Permissão de localização negada.');
      await Geolocator.openAppSettings();
      return;
    }
    try { await ph.Permission.locationAlways.request(); } catch (_) {}
    try { await ph.Permission.notification.request(); } catch (_) {}
  }

  Future<void> login() async {
    if (entrando) return;
    setState(() { entrando = true; status = 'Entrando...'; });
    try {
      await prepararPermissoes();
      final resp = await http.post(
        Uri.parse('$apiBase/app_login_motorista.php'),
        body: {
          'login': loginCtrl.text.trim(),
          'senha': senhaCtrl.text.trim(),
          'device_id': Platform.operatingSystem,
          'device_name': 'Android Macropac',
        },
      ).timeout(const Duration(seconds: 25));
      final json = jsonDecode(resp.body);
      if (json['success'] != true) throw Exception(json['message']?.toString() ?? 'Login não autorizado.');
      final token = json['token']?.toString() ?? '';
      if (token.isEmpty) throw Exception('API não retornou token.');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', token);
      final motNome = (json['motorista'] is Map) ? (json['motorista']['nome']?.toString() ?? 'Motorista') : (json['motorista_nome']?.toString() ?? 'Motorista');
      final camPlaca = (json['caminhao'] is Map) ? (json['caminhao']['placa']?.toString() ?? '-') : (json['caminhao_placa']?.toString() ?? '-');
      await prefs.setString('motorista_nome', motNome);
      await prefs.setString('caminhao_placa', camPlaca);
      setState(() { logado = true; motorista = motNome; caminhao = camPlaca; status = 'Login realizado. Iniciando rastreamento...'; });
      await iniciarRastreamentoAutomatico();
      iniciarTimerTela();
    } catch (e) {
      setState(() => status = 'Erro no login: $e');
    } finally {
      setState(() => entrando = false);
    }
  }

  Future<void> iniciarRastreamentoAutomatico() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token') ?? '';
      if (token.isEmpty) return;
      try {
        await http.post(Uri.parse('$apiBase/app_iniciar_rota.php'), body: {'token': token}).timeout(const Duration(seconds: 20));
      } catch (_) {}
      final service = FlutterBackgroundService();
      if (!await service.isRunning()) await service.startService();
      service.invoke('forcar_envio');
      setState(() => status = 'Rastreamento automático ativo em segundo plano.');
      await enviarUmaLocalizacaoTela();
    } catch (e) {
      setState(() => status = 'Erro ao iniciar rastreamento: $e');
    }
  }

  void iniciarTimerTela() {
    timerTela?.cancel();
    timerTela = Timer.periodic(const Duration(seconds: intervaloSegundos), (_) {
      enviarUmaLocalizacaoTela();
      FlutterBackgroundService().invoke('forcar_envio');
    });
    enviarUmaLocalizacaoTela();
  }

  Future<void> enviarUmaLocalizacaoTela() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token') ?? '';
      if (token.isEmpty) return;
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 20));
      int bat = -1;
      try { bat = await Battery().batteryLevel; } catch (_) {}
      final resp = await http.post(
        Uri.parse('$apiBase/app_salvar_localizacao.php'),
        body: {
          'token': token,
          'latitude': pos.latitude.toString(),
          'longitude': pos.longitude.toString(),
          'velocidade': pos.speed.isNaN ? '' : pos.speed.toString(),
          'precisao': pos.accuracy.isNaN ? '' : pos.accuracy.toString(),
          'bateria': bat >= 0 ? bat.toString() : '',
          'origem': 'apk_foreground',
        },
      ).timeout(const Duration(seconds: 25));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        setState(() {
          ultimaLatitude = pos.latitude.toStringAsFixed(8);
          ultimaLongitude = pos.longitude.toStringAsFixed(8);
          ultimaPrecisao = '${pos.accuracy.toStringAsFixed(1)} m';
          bateria = bat >= 0 ? '$bat%' : '-';
          ultimaAtualizacao = formatarHora(DateTime.now());
          status = 'Localização enviada com sucesso.';
        });
      } else {
        setState(() => status = 'Servidor recusou localização: ${resp.body}');
      }
    } catch (e) {
      setState(() => status = 'Aguardando GPS/internet: $e');
    }
  }

  Future<void> emergencia() async {
    setState(() => status = 'Enviando emergência...');
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token') ?? '';
      if (token.isEmpty) throw Exception('Sem token.');
      Position? pos;
      try { pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 15)); } catch (_) {}
      int bat = -1;
      try { bat = await Battery().batteryLevel; } catch (_) {}
      final resp = await http.post(
        Uri.parse('$apiBase/app_emergencia.php'),
        body: {
          'token': token,
          'latitude': pos?.latitude.toString() ?? '',
          'longitude': pos?.longitude.toString() ?? '',
          'bateria': bat >= 0 ? bat.toString() : '',
          'mensagem': 'Motorista pediu ajuda pelo aplicativo.',
        },
      ).timeout(const Duration(seconds: 25));
      setState(() => status = resp.statusCode < 300 ? 'Emergência enviada para a central.' : 'Erro ao enviar emergência: ${resp.body}');
    } catch (e) {
      setState(() => status = 'Erro emergência: $e');
    }
  }

  Future<void> sairParaTeste() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    FlutterBackgroundService().invoke('stop');
    setState(() { logado = false; motorista = ''; caminhao = ''; status = 'Sessão limpa. Faça login novamente.'; });
  }

  String formatarHora(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (carregando) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FB),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Container(
              width: 520,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black.withOpacity(.08))]),
              child: logado ? telaRastreamento() : telaLogin(),
            ),
          ),
        ),
      ),
    );
  }

  Widget telaLogin() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('MACROPAC', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
    const SizedBox(height: 4),
    const Text('Rastreamento de Frota'),
    const SizedBox(height: 24),
    TextField(controller: loginCtrl, decoration: const InputDecoration(labelText: 'Login do motorista', border: OutlineInputBorder())),
    const SizedBox(height: 12),
    TextField(controller: senhaCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Senha', border: OutlineInputBorder())),
    const SizedBox(height: 16),
    FilledButton(onPressed: entrando ? null : login, child: Text(entrando ? 'Entrando...' : 'Entrar')),
    const SizedBox(height: 14),
    Text(status, style: const TextStyle(color: Colors.black54)),
  ]);

  Widget telaRastreamento() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('MACROPAC', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
    const SizedBox(height: 4),
    const Text('Rastreamento automático ativo'),
    const SizedBox(height: 22),
    Card(elevation: 0, color: const Color(0xFFEFF6FF), child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      linha('Motorista', motorista),
      linha('Caminhão', caminhao),
      linha('Última atualização', ultimaAtualizacao),
      linha('Latitude', ultimaLatitude),
      linha('Longitude', ultimaLongitude),
      linha('Precisão', ultimaPrecisao),
      linha('Bateria', bateria),
    ]))),
    const SizedBox(height: 12),
    const Text('O rastreamento inicia automaticamente e continua em segundo plano enquanto o Android permitir.', style: TextStyle(fontWeight: FontWeight.w600)),
    const SizedBox(height: 16),
    FilledButton(onPressed: emergencia, style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C), padding: const EdgeInsets.symmetric(vertical: 16)), child: const Text('EMERGÊNCIA / PEDIR AJUDA')),
    const SizedBox(height: 12),
    OutlinedButton(onPressed: enviarUmaLocalizacaoTela, child: const Text('Atualizar agora')),
    const SizedBox(height: 8),
    Text(status, style: const TextStyle(color: Colors.black87)),
    const SizedBox(height: 8),
    TextButton(onPressed: sairParaTeste, child: const Text('Sair apenas para teste/admin')),
  ]);

  Widget linha(String titulo, String valor) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [SizedBox(width: 145, child: Text('$titulo:', style: const TextStyle(fontWeight: FontWeight.bold))), Expanded(child: Text(valor))]));
}
