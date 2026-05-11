import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

const String apiBase = 'https://mega4tech.com.br/macropac_rastreamento/api';
const int intervaloSegundos = 15;
const MethodChannel canalNativo = MethodChannel('macropac/native');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MacropacApp());
}

class MacropacApp extends StatelessWidget {
  const MacropacApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Macropac Rastreamento',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0F766E),
        useMaterial3: true,
      ),
      home: const TelaPrincipal(),
    );
  }
}

class TelaPrincipal extends StatefulWidget {
  const TelaPrincipal({super.key});

  @override
  State<TelaPrincipal> createState() => _TelaPrincipalState();
}

class _TelaPrincipalState extends State<TelaPrincipal> {
  final loginCtrl = TextEditingController(text: 'motorista.teste');
  final senhaCtrl = TextEditingController(text: '123456');

  bool carregando = true;
  bool entrando = false;
  bool logado = false;

  String status = 'Inicializando...';
  String motorista = '';
  String caminhao = '';
  String ultimaAtualizacao = '-';
  String lat = '-';
  String lng = '-';
  String precisao = '-';
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
        motorista = prefs.getString('motorista_nome') ?? 'Motorista';
        caminhao = prefs.getString('caminhao_placa') ?? '-';
        status = 'Sessão carregada. Iniciando rastreamento...';
        carregando = false;
      });

      await prepararPermissoes();
      await iniciarRastreamento();
      iniciarTimerComAppAberto();
    } else {
      setState(() {
        carregando = false;
        status = 'Informe login e senha.';
      });
    }
  }

  Future<void> prepararPermissoes() async {
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

    if (permissao == LocationPermission.deniedForever) {
      setState(() => status = 'Permissão de localização negada. Abra as configurações do app.');
      await Geolocator.openAppSettings();
      return;
    }

    try {
      await ph.Permission.notification.request();
    } catch (_) {}

    try {
      await ph.Permission.locationAlways.request();
    } catch (_) {}
  }

  Future<void> login() async {
    if (entrando) return;

    setState(() {
      entrando = true;
      status = 'Entrando...';
    });

    try {
      await prepararPermissoes();

      final resp = await http
          .post(
            Uri.parse('$apiBase/app_login_motorista.php'),
            body: {
              'login': loginCtrl.text.trim(),
              'senha': senhaCtrl.text.trim(),
              'device_id': Platform.operatingSystem,
              'device_name': 'Android Macropac',
            },
          )
          .timeout(const Duration(seconds: 25));

      Map<String, dynamic> json;
      try {
        json = jsonDecode(resp.body);
      } catch (_) {
        throw Exception('Resposta inválida da API: ${resp.body}');
      }

      if (json['success'] != true) {
        throw Exception(json['message']?.toString() ?? 'Login não autorizado.');
      }

      final token = json['token']?.toString() ?? '';
      if (token.isEmpty) throw Exception('Token não retornado pela API.');

      final motNome = json['motorista'] is Map
          ? json['motorista']['nome']?.toString() ?? 'Motorista'
          : json['motorista_nome']?.toString() ?? 'Motorista';

      final camPlaca = json['caminhao'] is Map
          ? json['caminhao']['placa']?.toString() ?? '-'
          : json['caminhao_placa']?.toString() ?? '-';

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', token);
      await prefs.setString('motorista_nome', motNome);
      await prefs.setString('caminhao_placa', camPlaca);

      setState(() {
        logado = true;
        motorista = motNome;
        caminhao = camPlaca;
        status = 'Login realizado. Iniciando segundo plano...';
      });

      await iniciarRastreamento();
      iniciarTimerComAppAberto();
    } catch (e) {
      setState(() => status = 'Erro no login: $e');
    } finally {
      setState(() => entrando = false);
    }
  }

  Future<void> iniciarRastreamento() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token') ?? '';
      if (token.isEmpty) return;

      try {
        await http
            .post(Uri.parse('$apiBase/app_iniciar_rota.php'), body: {'token': token})
            .timeout(const Duration(seconds: 20));
      } catch (_) {}

      final retorno = await canalNativo.invokeMethod('startTrackingService');
      setState(() => status = 'Segundo plano nativo ativo: $retorno');

      await enviarComAppAberto();
    } catch (e) {
      setState(() => status = 'Erro ao iniciar segundo plano: $e');
    }
  }

  void iniciarTimerComAppAberto() {
    timerTela?.cancel();
    timerTela = Timer.periodic(
      const Duration(seconds: intervaloSegundos),
      (_) => enviarComAppAberto(),
    );
    enviarComAppAberto();
  }

  Future<void> enviarComAppAberto() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token') ?? '';
      if (token.isEmpty) return;

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );

      int bat = -1;
      try {
        bat = await Battery().batteryLevel;
      } catch (_) {}

      final resp = await http
          .post(
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
          )
          .timeout(const Duration(seconds: 25));

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        setState(() {
          lat = pos.latitude.toStringAsFixed(8);
          lng = pos.longitude.toStringAsFixed(8);
          precisao = '${pos.accuracy.toStringAsFixed(1)} m';
          bateria = bat >= 0 ? '$bat%' : '-';
          ultimaAtualizacao = formatarHora(DateTime.now());
          status = 'Localização enviada. Segundo plano nativo ativo.';
        });
      } else {
        setState(() => status = 'Erro servidor: ${resp.body}');
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
      try {
        pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 15),
        );
      } catch (_) {}

      int bat = -1;
      try {
        bat = await Battery().batteryLevel;
      } catch (_) {}

      final resp = await http
          .post(
            Uri.parse('$apiBase/app_emergencia.php'),
            body: {
              'token': token,
              'latitude': pos?.latitude.toString() ?? '',
              'longitude': pos?.longitude.toString() ?? '',
              'bateria': bat >= 0 ? bat.toString() : '',
              'mensagem': 'Motorista pediu ajuda pelo aplicativo.',
            },
          )
          .timeout(const Duration(seconds: 25));

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        setState(() => status = 'Emergência enviada para a central.');
      } else {
        setState(() => status = 'Erro emergência: ${resp.body}');
      }
    } catch (e) {
      setState(() => status = 'Erro ao enviar emergência: $e');
    }
  }

  Future<void> sairTeste() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();

    try {
      await canalNativo.invokeMethod('stopTrackingService');
    } catch (_) {}

    timerTela?.cancel();

    setState(() {
      logado = false;
      motorista = '';
      caminhao = '';
      ultimaAtualizacao = '-';
      lat = '-';
      lng = '-';
      precisao = '-';
      bateria = '-';
      status = 'Sessão limpa para teste.';
    });
  }

  String formatarHora(DateTime d) {
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/'
        '${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}:'
        '${d.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (carregando) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      backgroundColor: const Color(0xFFF3F6FB),
      appBar: AppBar(title: const Text('Macropac Rastreamento')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Container(
            width: 560,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FFFC),
              borderRadius: BorderRadius.circular(18),
              boxShadow: [BoxShadow(blurRadius: 18, color: Colors.black.withOpacity(.12))],
            ),
            child: logado ? telaLogado() : telaLogin(),
          ),
        ),
      ),
    );
  }

  Widget telaLogin() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('MACROPAC', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
        const SizedBox(height: 18),
        TextField(
          controller: loginCtrl,
          decoration: const InputDecoration(labelText: 'Login', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: senhaCtrl,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Senha', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),
        FilledButton(onPressed: entrando ? null : login, child: Text(entrando ? 'Entrando...' : 'Entrar')),
        const SizedBox(height: 14),
        Text(status),
      ],
    );
  }

  Widget telaLogado() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('MACROPAC', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        linha('Motorista', motorista),
        linha('Caminhão', caminhao),
        linha('Última atualização', ultimaAtualizacao),
        linha('Latitude', lat),
        linha('Longitude', lng),
        linha('Precisão', precisao),
        linha('Bateria', bateria),
        const SizedBox(height: 16),
        const Text(
          'Rastreamento automático ativo. Para funcionar em segundo plano, mantenha localização, notificações e bateria sem restrição.',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: emergencia,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB91C1C), padding: const EdgeInsets.symmetric(vertical: 16)),
          child: const Text('EMERGÊNCIA / PEDIR AJUDA'),
        ),
        const SizedBox(height: 10),
        OutlinedButton(onPressed: enviarComAppAberto, child: const Text('Atualizar agora')),
        const SizedBox(height: 10),
        Text(status),
        const SizedBox(height: 10),
        TextButton(onPressed: sairTeste, child: const Text('Sair apenas para teste/admin')),
      ],
    );
  }

  Widget linha(String titulo, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text('$titulo:', style: const TextStyle(fontWeight: FontWeight.bold))),
          Expanded(child: Text(valor)),
        ],
      ),
    );
  }
}
