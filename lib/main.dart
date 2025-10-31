import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dio/dio.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Produits',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      debugShowCheckedModeBanner: false,
      home: LoginScreen(
        api: ApiClient(
          baseUrl: const String.fromEnvironment(
            'API_BASE_URL',
            defaultValue:
                'http://127.0.0.1:8000', // Android émulateur; iOS: http://localhost:8000
          ),
          auth: AuthStore(),
        ),
      ),
    );
  }
}

// -----------------------------
// STORAGE (JWT)
// -----------------------------
class AuthStore {
  static const _k = FlutterSecureStorage();
  static const _tokenKey = 'access_token';

  Future<void> saveToken(String token) =>
      _k.write(key: _tokenKey, value: token);
  Future<String?> readToken() => _k.read(key: _tokenKey);
  Future<void> clear() => _k.delete(key: _tokenKey);
}

// -----------------------------
// API CLIENT (Dio)
// -----------------------------
class UnauthorizedException implements Exception {
  final String message;
  UnauthorizedException([this.message = 'Unauthorized']);
  @override
  String toString() => 'UnauthorizedException: $message';
}

class ApiClient {
  ApiClient({required this.baseUrl, required this.auth, Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 10),
              headers: {'Accept': 'application/json'},
              responseType: ResponseType.json,
            ),
          );

  final String baseUrl; // ex: http://10.0.2.2:8000
  final AuthStore auth;
  final Dio _dio;

  Future<void> login({
    required String username,
    required String password,
  }) async {
    try {
      final r = await _dio.post(
        '/auth/login/',
        data: {'username': username, 'password': password},
        options: Options(contentType: Headers.jsonContentType),
      );

      if (r.statusCode == 200) {
        final data = r.data is Map<String, dynamic>
            ? r.data as Map<String, dynamic>
            : jsonDecode(r.data as String) as Map<String, dynamic>;
        final token = data['access_token'] as String?;
        if (token == null || token.isEmpty) {
          throw Exception('Réponse login invalide: token manquant');
        }
        await auth.saveToken(token);
        return;
      }

      if (r.statusCode == 401) {
        throw UnauthorizedException('Identifiants invalides');
      }

      throw Exception('Login échoué (${r.statusCode})');
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw UnauthorizedException('Identifiants invalides');
      }
      rethrow;
    }
  }

  Future<List<Product>> getProducts({
    String? q,
    int offset = 0,
    int limit = 20,
    CancelToken? cancelToken,
  }) async {
    final token = await auth.readToken();
    if (token == null) throw UnauthorizedException('Token absent');

    try {
      final r = await _dio.get(
        '/products',
        queryParameters: {
          if (q != null && q.trim().isNotEmpty) 'q': q,
          'offset': offset,
          'limit': limit,
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
        cancelToken: cancelToken,
      );

      if (r.statusCode == 200) {
        final data = r.data;
        late final List<dynamic> itemsJson;
        if (data is List) {
          itemsJson = data;
        } else if (data is Map<String, dynamic> && data['items'] is List) {
          itemsJson = data['items'] as List;
        } else if (data is String) {
          final parsed = jsonDecode(data);
          if (parsed is List) {
            itemsJson = parsed;
          } else if (parsed is Map<String, dynamic> &&
              parsed['items'] is List) {
            itemsJson = parsed['items'] as List;
          } else {
            throw Exception('Format de réponse inattendu');
          }
        } else {
          throw Exception('Format de réponse inattendu');
        }

        return itemsJson
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList();
      }

      if (r.statusCode == 401) {
        throw UnauthorizedException('Token expiré ou invalide');
      }

      throw Exception('GET /products échoué (${r.statusCode})');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        // Requête annulée (nouvelle recherche) → on ne propage pas comme erreur UI
        throw e; // sera ignoré côté UI
      }
      if (e.response?.statusCode == 401) {
        throw UnauthorizedException('Token expiré ou invalide');
      }
      throw Exception(
        'GET /products échoué (${e.response?.statusCode ?? e.message})',
      );
    }
  }
}

class Product {
  final int id;
  final String name;
  final int? kcal100g;
  final String? description;
  final String? imageUrl;
  final DateTime? updatedAt;

  Product({
    required this.id,
    required this.name,
    this.kcal100g,
    this.description,
    this.imageUrl,
    this.updatedAt,
  });

  factory Product.fromJson(Map<String, dynamic> j) => Product(
    id: (j['id'] as num).toInt(),
    name: j['name'] as String,
    kcal100g: j['kcal_100g'] == null ? null : (j['kcal_100g'] as num).toInt(),
    description: j['description'] as String?,
    imageUrl: j['image_url'] as String?,
    updatedAt: j['updated_at'] == null
        ? null
        : DateTime.tryParse(j['updated_at'] as String),
  );
}

class PaginatedProducts {
  final List<Product> items;
  final int page;
  final int limit;
  final int? total;
  final bool hasMore;

  PaginatedProducts({
    required this.items,
    required this.page,
    required this.limit,
    this.total,
    required this.hasMore,
  });

  factory PaginatedProducts.fromJson(Map<String, dynamic> j) =>
      PaginatedProducts(
        items: (j['items'] as List<dynamic>)
            .map((e) => Product.fromJson(e as Map<String, dynamic>))
            .toList(),
        page: (j['page'] as num).toInt(),
        limit: (j['limit'] as num).toInt(),
        total: j['total'] == null ? null : (j['total'] as num).toInt(),
        hasMore: (j['has_more'] as bool?) ?? false,
      );
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.api.login(
        username: _userCtrl.text.trim(),
        password: _passCtrl.text,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => ProductsScreen(api: widget.api)),
      );
    } on UnauthorizedException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Erreur: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connexion')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _userCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Identifiant',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Requis' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Mot de passe',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    obscureText: true,
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Requis' : null,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Se connecter'),
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

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key, required this.api});
  final ApiClient api;

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _Debouncer {
  _Debouncer(this.delay);
  final Duration delay;
  Timer? _t;
  void run(void Function() action) {
    _t?.cancel();
    _t = Timer(delay, action);
  }

  void dispose() {
    _t?.cancel();
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Aucun produit'));
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _debouncer = _Debouncer(const Duration(milliseconds: 400));

  final List<Product> _items = [];
  bool _loading = false; // chargement initial ou "lot suivant"
  bool _refreshing = false; // pull-to-refresh
  bool _error = false;
  String? _errorMsg;
  bool _hasMore = true;
  int _offset = 0;
  static const int _limit = 20;
  String _q = '';

  CancelToken?
  _inflight; // pour annuler une requête lors d'une nouvelle recherche

  @override
  void initState() {
    super.initState();
    _fetch(reset: true);
    _scrollCtrl.addListener(_onScroll);
    _searchCtrl.addListener(() {
      _debouncer.run(() {
        final newQ = _searchCtrl.text.trim();
        if (newQ != _q) {
          _q = newQ;
          _fetch(reset: true);
        }
      });
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    _debouncer.dispose();
    _inflight?.cancel('cleanup');
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loading || _refreshing) return;
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 200) {
      _fetch();
    }
  }

  Future<void> _fetch({bool reset = false}) async {
    if (_loading || _refreshing) return;

    if (reset) {
      // Annule la requête en cours s'il y en a une
      _inflight?.cancel('new search');
      setState(() {
        _offset = 0;
        _hasMore = true;
        _error = false;
        _errorMsg = null;
        _items.clear();
      });
    }

    if (!_hasMore) return;

    setState(() => _loading = true);
    final token = _inflight = CancelToken();
    try {
      final newItems = await widget.api.getProducts(
        q: _q.isEmpty ? null : _q,
        offset: _offset,
        limit: _limit,
        cancelToken: token,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(newItems);
        // Si on reçoit moins que limit, il n'y a plus de page suivante
        if (newItems.length < _limit) _hasMore = false;
        _offset += newItems.length;
        _error = false;
        _errorMsg = null;
      });
    } on DioException catch (e) {
      // Si c'est une annulation (nouvelle recherche), on ignore
      if (!CancelToken.isCancel(e)) {
        setState(() {
          _error = true;
          _errorMsg = e.message;
        });
      }
    } on UnauthorizedException {
      // Token KO → purge + retour login
      await widget.api.auth.clear();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => LoginScreen(api: widget.api)),
        (route) => false,
      );
    } catch (e) {
      setState(() {
        _error = true;
        _errorMsg = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await _fetch(reset: true);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _logout() async {
    await widget.api.auth.clear();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen(api: widget.api)),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Produits'),
        actions: [
          IconButton(
            tooltip: 'Déconnexion',
            onPressed: _logout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Rechercher un produit…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Effacer',
                        onPressed: () {
                          _searchCtrl.clear();
                          _q = '';
                          _fetch(reset: true);
                        },
                        icon: const Icon(Icons.clear),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: _error
                  ? _ErrorView(
                      message: _errorMsg ?? 'Erreur inconnue',
                      onRetry: () => _fetch(reset: true),
                    )
                  : _items.isEmpty && !_loading
                  ? const _EmptyView()
                  : ListView.builder(
                      controller: _scrollCtrl,
                      itemCount: _items.length + (_hasMore ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= _items.length) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }
                        final item = _items[i];
                        return ListTile(
                          title: Text(item.name),
                          subtitle: item.description != null
                              ? Text(
                                  item.description!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                )
                              : null,
                          trailing: item.kcal100g != null
                              ? Text('${item.kcal100g} kcal')
                              : null,
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
