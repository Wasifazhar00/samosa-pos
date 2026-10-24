import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:share_plus/share_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  runApp(const SamosaPosApp());
}

/* ============================================================================
 * DATA MODELS
 * ========================================================================= */
class MenuItem {
  final int? id;
  final String nameEn;
  final String nameUr;
  final double price;
  final String icon;
  final bool inStock;

  MenuItem({
    this.id,
    required this.nameEn,
    required this.nameUr,
    required this.price,
    required this.icon,
    this.inStock = true,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name_en': nameEn,
        'name_ur': nameUr,
        'price': price,
        'icon': icon,
        'in_stock': inStock ? 1 : 0,
      };

  factory MenuItem.fromMap(Map<String, dynamic> map) => MenuItem(
        id: map['id'],
        nameEn: map['name_en'] ?? '',
        nameUr: map['name_ur'] ?? '',
        price: (map['price'] as num).toDouble(),
        icon: map['icon'] ?? '🥟',
        inStock: map['in_stock'] == 1,
      );
}

class InventoryItem {
  final int? id;
  final String name;
  final double stockQty;
  final String unit;

  InventoryItem({this.id, required this.name, required this.stockQty, required this.unit});

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'stock_qty': stockQty,
        'unit': unit,
      };

  factory InventoryItem.fromMap(Map<String, dynamic> map) => InventoryItem(
        id: map['id'],
        name: map['name'] ?? '',
        stockQty: (map['stock_qty'] as num).toDouble(),
        unit: map['unit'] ?? 'pcs',
      );
}

class CartItem {
  final MenuItem item;
  int quantity;
  double customPrice;

  CartItem({required this.item, this.quantity = 1, double? customPrice})
      : customPrice = customPrice ?? item.price;

  double get total => customPrice * quantity;
}

class SaleRecord {
  final int? id;
  final String billNo;
  final String tokenNo;
  final String orderType;
  final String itemsSummary;
  final String? customerMobile;
  final String? customerAddress;
  final double totalAmount;
  final String paymentMethod;
  final bool isPaid;
  final String createdAt;

  SaleRecord({
    this.id,
    required this.billNo,
    required this.tokenNo,
    required this.orderType,
    required this.itemsSummary,
    this.customerMobile,
    this.customerAddress,
    required this.totalAmount,
    required this.paymentMethod,
    required this.isPaid,
    required this.createdAt,
  });

  factory SaleRecord.fromMap(Map<String, dynamic> map) => SaleRecord(
        id: map['id'],
        billNo: map['bill_no'] ?? '',
        tokenNo: map['token_no'] ?? '',
        orderType: map['order_type'] ?? 'Dine-In',
        itemsSummary: map['items_summary'] ?? '',
        customerMobile: map['customer_mobile'],
        customerAddress: map['customer_address'],
        totalAmount: (map['total_amount'] as num).toDouble(),
        paymentMethod: map['payment_method'] ?? 'Cash',
        isPaid: map['is_paid'] == 1,
        createdAt: map['created_at'] ?? '',
      );
}

class OrderToken {
  final String id;
  final String tokenNo;
  final String tableName;
  final List<CartItem> items;
  final DateTime timeSeated;

  OrderToken({
    required this.id,
    required this.tokenNo,
    required this.tableName,
    required this.items,
    required this.timeSeated,
  });

  double get total => items.fold(0, (sum, item) => sum + item.total);
}

/* ============================================================================
 * DATABASE HELPER
 * ========================================================================= */
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('bismillah_samosa_pos_v10.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''CREATE TABLE IF NOT EXISTS stock_movements (
            id INTEGER PRIMARY KEY AUTOINCREMENT, sale_id INTEGER NOT NULL,
            inventory_id INTEGER NOT NULL, quantity REAL NOT NULL
          )''');
          await db.execute('''CREATE TABLE IF NOT EXISTS active_orders (
            id TEXT PRIMARY KEY, token_no TEXT NOT NULL, table_name TEXT NOT NULL,
            items_json TEXT NOT NULL, time_seated TEXT NOT NULL
          )''');
          // Repair duplicate legacy bill numbers before enforcing uniqueness.
          final legacySales = await db.query('sales', columns: ['id', 'bill_no'], orderBy: 'id ASC');
          final seenBills = <String>{};
          for (final row in legacySales) {
            final id = row['id'] as int;
            final bill = (row['bill_no'] as String?)?.trim() ?? '';
            if (bill.isEmpty || !seenBills.add(bill)) {
              final repaired = 'INV-LEGACY-$id';
              await db.update('sales', {'bill_no': repaired}, where: 'id = ?', whereArgs: [id]);
              seenBills.add(repaired);
            }
          }
          await db.execute('CREATE UNIQUE INDEX IF NOT EXISTS idx_sales_bill_no ON sales(bill_no)');
        }
      },
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE menu (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name_en TEXT,
        name_ur TEXT,
        price REAL,
        icon TEXT,
        in_stock INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE inventory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        stock_qty REAL,
        unit TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE recipes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        menu_id INTEGER,
        inventory_id INTEGER,
        required_qty REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE sales (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bill_no TEXT UNIQUE,
        token_no TEXT,
        order_type TEXT,
        items_summary TEXT,
        customer_mobile TEXT,
        customer_address TEXT,
        total_amount REAL,
        payment_method TEXT,
        is_paid INTEGER,
        created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE stock_movements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sale_id INTEGER NOT NULL,
        inventory_id INTEGER NOT NULL,
        quantity REAL NOT NULL
      )
    ''');
    await db.execute('''CREATE TABLE active_orders (
      id TEXT PRIMARY KEY, token_no TEXT NOT NULL, table_name TEXT NOT NULL,
      items_json TEXT NOT NULL, time_seated TEXT NOT NULL
    )''');

    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    await _seedDefaults(db);
  }

  Future<void> _seedDefaults(Database db) async {
    await db.insert('settings', {'key': 'shop_name', 'value': 'Bismillah Shereen Mehal Samosa POS'});
    await db.insert('settings', {'key': 'shop_address', 'value': 'Main Chowk, Layyah'});
    await db.insert('settings', {'key': 'shop_phone', 'value': '+92 300 1234567'});
    await db.insert('settings', {'key': 'payment_account_info', 'value': 'EasyPaisa/JazzCash: 03001234567'});
    await db.insert('settings', {'key': 'enable_dine_in', 'value': '1'});
    await db.insert('settings', {'key': 'enable_takeaway', 'value': '1'});
    await db.insert('settings', {'key': 'enable_delivery', 'value': '1'});

    int patiId = await db.insert('inventory', {'name': 'Samosa Pati', 'stock_qty': 500, 'unit': 'pcs'});
    int chanaId = await db.insert('inventory', {'name': 'Chana', 'stock_qty': 100, 'unit': 'servings'});
    int chatniId = await db.insert('inventory', {'name': 'Chatni', 'stock_qty': 100, 'unit': 'servings'});
    int chickenId = await db.insert('inventory', {'name': 'Chicken Filling', 'stock_qty': 50, 'unit': 'kg'});
    int alooId = await db.insert('inventory', {'name': 'Aloo Filling', 'stock_qty': 50, 'unit': 'kg'});
    int cokeId = await db.insert('inventory', {'name': 'Cold Drink (Coke)', 'stock_qty': 40, 'unit': 'bottles'});

    int m1 = await db.insert('menu', {'name_en': 'Chicken Samosa', 'name_ur': 'Chicken Samosa', 'price': 50, 'icon': '🍗', 'in_stock': 1});
    int m2 = await db.insert('menu', {'name_en': 'Aloo Samosa', 'name_ur': 'Aloo Samosa', 'price': 30, 'icon': '🥔', 'in_stock': 1});
    int m3 = await db.insert('menu', {'name_en': 'Single Plate', 'name_ur': 'Single Plate', 'price': 80, 'icon': '🥟', 'in_stock': 1});
    int m4 = await db.insert('menu', {'name_en': 'Double Plate', 'name_ur': 'Double Plate', 'price': 140, 'icon': '🥟', 'in_stock': 1});
    int m5 = await db.insert('menu', {'name_en': 'Cold Drink', 'name_ur': 'Cold Drink', 'price': 70, 'icon': '🥤', 'in_stock': 1});

    await db.insert('recipes', {'menu_id': m1, 'inventory_id': patiId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m1, 'inventory_id': chickenId, 'required_qty': 0.05});

    await db.insert('recipes', {'menu_id': m2, 'inventory_id': patiId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m2, 'inventory_id': alooId, 'required_qty': 0.05});

    await db.insert('recipes', {'menu_id': m3, 'inventory_id': patiId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m3, 'inventory_id': chanaId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m3, 'inventory_id': chatniId, 'required_qty': 1});

    await db.insert('recipes', {'menu_id': m4, 'inventory_id': patiId, 'required_qty': 2});
    await db.insert('recipes', {'menu_id': m4, 'inventory_id': chanaId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m4, 'inventory_id': chatniId, 'required_qty': 1});

    await db.insert('recipes', {'menu_id': m5, 'inventory_id': cokeId, 'required_qty': 1});
  }

  Future<List<MenuItem>> getMenuItems() async {
    final db = await instance.database;
    final result = await db.query('menu');
    return result.map((json) => MenuItem.fromMap(json)).toList();
  }

  Future<int> addMenuItem(MenuItem item) async {
    final db = await instance.database;
    return await db.insert('menu', item.toMap());
  }

  Future<int> updateMenuItem(MenuItem item) async {
    final db = await instance.database;
    return await db.update('menu', item.toMap(), where: 'id = ?', whereArgs: [item.id]);
  }

  Future<int> deleteMenuItem(int id) async {
    final db = await instance.database;
    return db.transaction((txn) async {
      await txn.delete('recipes', where: 'menu_id = ?', whereArgs: [id]);
      return txn.delete('menu', where: 'id = ?', whereArgs: [id]);
    });
  }


  Future<void> saveRecipesForMenuItem(int menuId, List<Map<String, dynamic>> recipes) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.delete('recipes', where: 'menu_id = ?', whereArgs: [menuId]);
      for (final recipe in recipes) {
        final inventoryId = recipe['inventory_id'] as int;
        final requiredQty = (recipe['required_qty'] as num).toDouble();
        if (!requiredQty.isFinite || requiredQty <= 0) throw ArgumentError('Recipe quantities must be greater than zero.');
        await txn.insert('recipes', {'menu_id': menuId, 'inventory_id': inventoryId, 'required_qty': requiredQty});
      }
    });
  }

  Future<List<Map<String, dynamic>>> getRecipesForMenuItem(int menuId) async {
    final db = await instance.database;
    return db.rawQuery('''SELECT recipes.inventory_id, recipes.required_qty, inventory.name, inventory.unit
      FROM recipes INNER JOIN inventory ON inventory.id = recipes.inventory_id WHERE recipes.menu_id = ?''', [menuId]);
  }

  Future<List<InventoryItem>> getInventory() async {
    final db = await instance.database;
    final result = await db.query('inventory');
    return result.map((json) => InventoryItem.fromMap(json)).toList();
  }

  Future<int> addInventoryItem(InventoryItem item) async {
    final db = await instance.database;
    return await db.insert('inventory', item.toMap());
  }

  Future<int> deleteInventoryItem(int id) async {
    final db = await instance.database;
    return db.transaction((txn) async {
      await txn.delete('recipes', where: 'inventory_id = ?', whereArgs: [id]);
      return txn.delete('inventory', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<int> updateStockQty(int id, double newQty) async {
    final db = await instance.database;
    return await db.rawUpdate('UPDATE inventory SET stock_qty = ? WHERE id = ?', [newQty, id]);
  }

  Future<List<SaleRecord>> getAllSales() async {
    final db = await instance.database;
    final result = await db.query('sales', orderBy: 'id DESC');
    return result.map((json) => SaleRecord.fromMap(json)).toList();
  }

  Future<void> updatePaymentStatus(int saleId, bool isPaid) async {
    final db = await instance.database;
    await db.update('sales', {'is_paid': isPaid ? 1 : 0}, where: 'id = ?', whereArgs: [saleId]);
  }

  Future<void> updateSaleDetails(int saleId, double newAmount, String mobile, String address) async {
    if (!newAmount.isFinite || newAmount < 0) throw ArgumentError('Amount must be non-negative.');
    final db = await instance.database;
    await db.update(
      'sales',
      {
        'total_amount': newAmount,
        'customer_mobile': mobile.isNotEmpty ? mobile : null,
        'customer_address': address.isNotEmpty ? address : null,
      },
      where: 'id = ?',
      whereArgs: [saleId],
    );
  }

  Future<void> deleteSale(int saleId) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      final movements = await txn.query('stock_movements', where: 'sale_id = ?', whereArgs: [saleId]);
      for (final movement in movements) {
        final inventoryId = movement['inventory_id'] as int;
        final quantity = (movement['quantity'] as num).toDouble();
        await txn.rawUpdate('UPDATE inventory SET stock_qty = stock_qty + ? WHERE id = ?', [quantity, inventoryId]);
      }
      await txn.delete('stock_movements', where: 'sale_id = ?', whereArgs: [saleId]);
      await txn.delete('sales', where: 'id = ?', whereArgs: [saleId]);
    });
  }

  Future<String> processSale({
    required List<CartItem> cartItems,
    required String paymentMethod,
    required String tokenNo,
    required String orderType,
    required bool isPaid,
    required double finalTotal,
    String? mobile,
    String? address,
  }) async {
    if (cartItems.isEmpty) {
      throw ArgumentError('Cannot save an empty sale.');
    }
    if (!finalTotal.isFinite || finalTotal < 0) {
      throw ArgumentError('Sale total must be a valid non-negative amount.');
    }

    final db = await instance.database;
    final now = DateTime.now();
    final billNo = 'INV-${now.microsecondsSinceEpoch}';

    await db.transaction((txn) async {
      final itemNames = <String>[];
      for (final cart in cartItems) {
        itemNames.add('${cart.quantity}x ${cart.item.nameEn}');
      }
      final saleId = await txn.insert('sales', {
        'bill_no': billNo,
        'token_no': tokenNo,
        'order_type': orderType,
        'items_summary': itemNames.join(', '),
        'customer_mobile': mobile,
        'customer_address': address,
        'total_amount': finalTotal,
        'payment_method': paymentMethod,
        'is_paid': isPaid ? 1 : 0,
        'created_at': now.toIso8601String(),
      });

      for (final cart in cartItems) {
        if (cart.quantity <= 0 || !cart.customPrice.isFinite || cart.customPrice < 0) {
          throw ArgumentError('Sale contains an invalid quantity or price.');
        }
        final recipes = await txn.query(
          'recipes',
          where: 'menu_id = ?',
          whereArgs: [cart.item.id],
        );
        if (recipes.isEmpty) {
          throw StateError('No stock recipe is configured for ${cart.item.nameEn}. Add its ingredient recipe before selling it.');
        }

        for (final rule in recipes) {
          final invId = rule['inventory_id'] as int;
          final reqQty = (rule['required_qty'] as num).toDouble();
          final deduction = reqQty * cart.quantity;
          final inventoryRows = await txn.query(
            'inventory',
            columns: ['stock_qty', 'name', 'unit'],
            where: 'id = ?',
            whereArgs: [invId],
            limit: 1,
          );

          if (inventoryRows.isEmpty) {
            throw StateError('Inventory item $invId was not found.');
          }

          final available = (inventoryRows.first['stock_qty'] as num).toDouble();
          if (available < deduction) {
            throw StateError(
              'Insufficient stock for ${inventoryRows.first['name']}. '
              'Available: $available ${inventoryRows.first['unit']}.',
            );
          }

          final updated = await txn.rawUpdate(
            'UPDATE inventory SET stock_qty = stock_qty - ? WHERE id = ? AND stock_qty >= ?',
            [deduction, invId, deduction],
          );
          if (updated != 1) {
            throw StateError('Stock changed during checkout for ${inventoryRows.first['name']}. Please retry.');
          }
          await txn.insert('stock_movements', {
            'sale_id': saleId, 'inventory_id': invId, 'quantity': deduction,
          });
        }
      }

    });

    return billNo;
  }


  Future<void> saveActiveOrder(OrderToken token) async {
    final db = await instance.database;
    final items = token.items.map((c) => {
      'menu_id': c.item.id, 'quantity': c.quantity, 'custom_price': c.customPrice,
    }).toList();
    await db.insert('active_orders', {
      'id': token.id, 'token_no': token.tokenNo, 'table_name': token.tableName,
      'items_json': jsonEncode(items), 'time_seated': token.timeSeated.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<OrderToken>> getActiveOrders() async {
    final db = await instance.database;
    final rows = await db.query('active_orders', orderBy: 'time_seated ASC');
    final result = <OrderToken>[];
    for (final row in rows) {
      final rawItems = jsonDecode(row['items_json'] as String) as List<dynamic>;
      final items = <CartItem>[];
      for (final raw in rawItems) {
        final data = Map<String, dynamic>.from(raw as Map);
        final menuRows = await db.query('menu', where: 'id = ?', whereArgs: [data['menu_id']], limit: 1);
        if (menuRows.isEmpty) continue;
        items.add(CartItem(
          item: MenuItem.fromMap(menuRows.first),
          quantity: data['quantity'] as int,
          customPrice: (data['custom_price'] as num).toDouble(),
        ));
      }
      result.add(OrderToken(
        id: row['id'] as String, tokenNo: row['token_no'] as String,
        tableName: row['table_name'] as String, items: items,
        timeSeated: DateTime.tryParse(row['time_seated'] as String) ?? DateTime.now(),
      ));
    }
    return result;
  }

  Future<void> deleteActiveOrder(String id) async {
    final db = await instance.database;
    await db.delete('active_orders', where: 'id = ?', whereArgs: [id]);
  }

  Future<String> getSetting(String key, {String defaultValue = ''}) async {
    final db = await instance.database;
    final result = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (result.isNotEmpty) {
      return result.first['value'] as String;
    }
    return defaultValue;
  }

  Future<void> setSetting(String key, String value) async {
    final db = await instance.database;
    await db.insert('settings', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String> getDatabasePath() async {
    final dbPath = await getDatabasesPath();
    return p.join(dbPath, 'bismillah_samosa_pos_v10.db');
  }
}

/* ============================================================================
 * MAIN APPLICATION WIDGET
 * ========================================================================= */
class SamosaPosApp extends StatefulWidget {
  const SamosaPosApp({super.key});

  @override
  State<SamosaPosApp> createState() => _SamosaPosAppState();
}

class _SamosaPosAppState extends State<SamosaPosApp> {
  bool isUrdu = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bismillah Shereen Mehal Samosa POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD84315),
          primary: const Color(0xFFD84315),
          secondary: const Color(0xFF2E7D32),
        ),
        fontFamily: 'Roboto',
      ),
      home: MainPosScreen(
        isUrdu: isUrdu,
        onToggleLanguage: () => setState(() => isUrdu = !isUrdu),
      ),
    );
  }
}

/* ============================================================================
 * MAIN POS SCREEN CONTAINER
 * ========================================================================= */
class MainPosScreen extends StatefulWidget {
  final bool isUrdu;
  final VoidCallback onToggleLanguage;

  const MainPosScreen({super.key, required this.isUrdu, required this.onToggleLanguage});

  @override
  State<MainPosScreen> createState() => _MainPosScreenState();
}

class _MainPosScreenState extends State<MainPosScreen> {
  int _selectedIndex = 0;
  List<CartItem> cart = [];
  List<OrderToken> activeTokens = [];
  String activeTable = 'Table 1';
  String currentTokenNo = '1-A';
  String shopName = 'Bismillah Shereen Mehal Samosa POS';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadActiveOrders();
  }

  Future<void> _loadActiveOrders() async {
    final orders = await DatabaseHelper.instance.getActiveOrders();
    if (!mounted) return;
    setState(() => activeTokens = orders);
  }

  Future<void> _saveCurrentTableOrder() async {
    final index = activeTokens.indexWhere((t) => t.tokenNo == currentTokenNo && t.tableName == activeTable);
    final token = OrderToken(
      id: index >= 0 ? activeTokens[index].id : DateTime.now().microsecondsSinceEpoch.toString(),
      tokenNo: currentTokenNo, tableName: activeTable,
      items: cart.map((c) => CartItem(item: c.item, quantity: c.quantity, customPrice: c.customPrice)).toList(),
      timeSeated: index >= 0 ? activeTokens[index].timeSeated : DateTime.now(),
    );
    await DatabaseHelper.instance.saveActiveOrder(token);
    if (!mounted) return;
    setState(() { if (index >= 0) activeTokens[index] = token; else activeTokens.add(token); });
  }

  void _loadSettings() async {
    String name = await DatabaseHelper.instance.getSetting('shop_name', defaultValue: 'Bismillah Shereen Mehal Samosa POS');
    if (!mounted) return;
    setState(() {
      shopName = name;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        title: Text(
          shopName,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 18),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: widget.onToggleLanguage,
              icon: const Icon(Icons.language, color: Colors.black, size: 20),
              label: Text(
                widget.isUrdu ? 'English' : 'Urdu',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          PosTerminalView(
            key: ValueKey('pos-$_selectedIndex'),
            isUrdu: widget.isUrdu,
            cart: cart,
            tokenNo: currentTokenNo,
            tableName: activeTable,
            onAddToCart: (item) => setState(() {
              int idx = cart.indexWhere((c) => c.item.id == item.id);
              if (idx >= 0) {
                cart[idx].quantity++;
              } else {
                cart.add(CartItem(item: item));
              }
            }),
            onClearCart: () => setState(() => cart.clear()),
            onCheckoutSuccess: (orderType) { final old = activeTokens.where((t) => t.tokenNo == currentTokenNo && t.tableName == activeTable).toList(); for (final t in old) { DatabaseHelper.instance.deleteActiveOrder(t.id); } setState(() { cart.clear(); activeTokens.removeWhere((t) => t.tokenNo == currentTokenNo && t.tableName == activeTable); currentTokenNo = 'T-${DateTime.now().millisecondsSinceEpoch}'; }); },
            onSaveTableOrder: _saveCurrentTableOrder,
          ),
          TablesView(
            isUrdu: widget.isUrdu,
            tokens: activeTokens,
            onSelectToken: (token) {
              setState(() {
                final existing = activeTokens.indexWhere((t) => t.id == token.id);
                if (existing < 0) activeTokens.add(token);
                cart = token.items.map((c) => CartItem(item: c.item, quantity: c.quantity, customPrice: c.customPrice)).toList();
                activeTable = token.tableName;
                currentTokenNo = token.tokenNo;
                _selectedIndex = 0;
              });
            },
          ),
          MenuManagementView(isUrdu: widget.isUrdu),
          InventoryView(isUrdu: widget.isUrdu),
          ReportsAndSalesHistoryView(isUrdu: widget.isUrdu),
          SettingsView(
            isUrdu: widget.isUrdu,
            onSettingsSaved: _loadSettings,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.point_of_sale),
            label: 'POS',
          ),
          NavigationDestination(
            icon: Icon(Icons.table_restaurant),
            label: 'Tables',
          ),
          NavigationDestination(
            icon: Icon(Icons.restaurant_menu),
            label: 'Menu',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory),
            label: 'Stock',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long),
            label: 'Transactions',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/* ============================================================================
 * VIEW 1: POS TERMINAL VIEW
 * ========================================================================= */
class PosTerminalView extends StatefulWidget {
  final bool isUrdu;
  final List<CartItem> cart;
  final String tokenNo;
  final String tableName;
  final Function(MenuItem) onAddToCart;
  final VoidCallback onClearCart;
  final ValueChanged<String> onCheckoutSuccess;
  final VoidCallback onSaveTableOrder;

  const PosTerminalView({
    super.key,
    required this.isUrdu,
    required this.cart,
    required this.tokenNo,
    required this.tableName,
    required this.onAddToCart,
    required this.onClearCart,
    required this.onCheckoutSuccess,
    required this.onSaveTableOrder,
  });

  @override
  State<PosTerminalView> createState() => _PosTerminalViewState();
}

class _PosTerminalViewState extends State<PosTerminalView> {
  late Future<List<MenuItem>> _menuItemsFuture;
  String selectedOrderType = 'Dine-In';
  final mobileCtrl = TextEditingController();
  final addressCtrl = TextEditingController();
  final discountCtrl = TextEditingController();
  double discount = 0;

  bool enableDineIn = true;
  bool enableTakeaway = true;
  bool enableDelivery = true;

  @override
  void initState() {
    super.initState();
    _refreshMenu();
    _loadOrderTypeSettings();
  }

  void _loadOrderTypeSettings() async {
    String d = await DatabaseHelper.instance.getSetting('enable_dine_in', defaultValue: '1');
    String t = await DatabaseHelper.instance.getSetting('enable_takeaway', defaultValue: '1');
    String del = await DatabaseHelper.instance.getSetting('enable_delivery', defaultValue: '1');
    if (!mounted) return;

    setState(() {
      enableDineIn = d == '1';
      enableTakeaway = t == '1';
      enableDelivery = del == '1';
      if (!enableDineIn && enableTakeaway) selectedOrderType = 'Takeaway';
      if (!enableDineIn && !enableTakeaway && enableDelivery) selectedOrderType = 'Delivery';
    });
  }

  void _refreshMenu() {
    setState(() {
      _menuItemsFuture = DatabaseHelper.instance.getMenuItems();
    });
  }

  @override
  void dispose() {
    mobileCtrl.dispose();
    addressCtrl.dispose();
    discountCtrl.dispose();
    super.dispose();
  }

  double get subTotal => widget.cart.fold(0, (sum, item) => sum + item.total);
  double get grandTotal => subTotal - discount.clamp(0, subTotal).toDouble() < 0 ? 0 : subTotal - discount.clamp(0, subTotal).toDouble();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        bool isMobilePortrait = constraints.maxWidth < 600;

        if (isMobilePortrait) {
          return Column(
            children: [
              _buildOrderTypeSelector(),
              Expanded(
                flex: 3,
                child: _buildMenuGrid(crossAxisCount: 2),
              ),
              Card(
                margin: const EdgeInsets.all(4),
                elevation: 6,
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Cart (${widget.cart.length} items)', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          Text('TOTAL: Rs. ${grandTotal.toStringAsFixed(0)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.green)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (selectedOrderType == 'Delivery') ...[
                        TextField(controller: mobileCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Mobile Number (Required)', prefixIcon: Icon(Icons.phone), isDense: true)),
                        const SizedBox(height: 4),
                        TextField(controller: addressCtrl, decoration: const InputDecoration(labelText: 'Delivery Address', prefixIcon: Icon(Icons.home), isDense: true)),
                      ],
                      Row(children: [
                        const Text('Discount Rs.'),
                        const SizedBox(width: 8),
                        SizedBox(width: 90, child: TextField(controller: discountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true), onChanged: (v) => setState(() => discount = (double.tryParse(v) ?? 0).clamp(0, subTotal).toDouble()))),
                      ]),
                      if (widget.cart.isNotEmpty)
                        SizedBox(height: 70, child: ListView.builder(scrollDirection: Axis.horizontal, itemCount: widget.cart.length, itemBuilder: (context, index) { final c = widget.cart[index]; return Card(child: Padding(padding: const EdgeInsets.all(6), child: Row(mainAxisSize: MainAxisSize.min, children: [Text('${c.item.nameEn} x${c.quantity}'), IconButton(icon: const Icon(Icons.remove_circle, color: Colors.red), onPressed: () => setState(() { if (c.quantity > 1) { c.quantity--; } else { widget.cart.removeAt(index); } })),]))); })),
                      if (selectedOrderType == 'Dine-In' && widget.cart.isNotEmpty)
                        SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () { widget.onSaveTableOrder(); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Table order saved.'))); }, icon: const Icon(Icons.table_restaurant), label: const Text('Save Table Order'))),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: widget.onClearCart,
                              child: const Text('Cancel', style: TextStyle(color: Colors.red)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                              onPressed: widget.cart.isEmpty ? null : () => _showCheckoutDialog(context),
                              child: const Text(
                                'Checkout Options',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        } else {
          return Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildMenuGrid(crossAxisCount: 3),
              ),
              Expanded(
                flex: 2,
                child: Card(
                  margin: const EdgeInsets.all(8),
                  elevation: 6,
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      children: [
                        _buildOrderTypeSelector(),
                        const SizedBox(height: 8),
                        if (selectedOrderType == 'Delivery') ...[
                          TextField(
                            controller: mobileCtrl,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'Mobile Number (Required)',
                              prefixIcon: Icon(Icons.phone),
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 6),
                          TextField(
                            controller: addressCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Address (Optional)',
                              prefixIcon: Icon(Icons.home),
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Expanded(
                          child: widget.cart.isEmpty
                              ? const Center(
                                  child: Text(
                                    'Cart is empty',
                                    style: TextStyle(fontSize: 16, color: Colors.grey),
                                  ),
                                )
                              : ListView.separated(
                                  itemCount: widget.cart.length,
                                  separatorBuilder: (c, i) => const Divider(height: 1),
                                  itemBuilder: (context, index) {
                                    final cartItem = widget.cart[index];
                                    return ListTile(
                                      dense: true,
                                      title: Text(
                                        cartItem.item.nameEn,
                                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                      ),
                                      subtitle: Text('Rs. ${cartItem.customPrice} x ${cartItem.quantity}'),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text('Rs. ${cartItem.total.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                          IconButton(
                                            icon: const Icon(Icons.remove_circle, color: Colors.red, size: 20),
                                            onPressed: () {
                                              setState(() {
                                                if (cartItem.quantity > 1) {
                                                  cartItem.quantity--;
                                                } else {
                                                  widget.cart.removeAt(index);
                                                }
                                              });
                                            },
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Discount:'),
                            SizedBox(
                              width: 90,
                              child: TextField(
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                                controller: discountCtrl,
                                onChanged: (v) => setState(() => discount = (double.tryParse(v) ?? 0).clamp(0, subTotal).toDouble()),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (selectedOrderType == 'Dine-In' && widget.cart.isNotEmpty)
                          SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () { widget.onSaveTableOrder(); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Table order saved.'))); }, icon: const Icon(Icons.table_restaurant), label: const Text('Save Table Order'))),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(10)),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('TOTAL:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              Text('Rs. ${grandTotal.toStringAsFixed(0)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.green)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(vertical: 14)),
                                onPressed: widget.onClearCart,
                                child: const Text('Cancel', style: TextStyle(color: Colors.white, fontSize: 16)),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(vertical: 14)),
                                onPressed: widget.cart.isEmpty ? null : () => _showCheckoutDialog(context),
                                child: const Text('Checkout Options', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }
      },
    );
  }

  Widget _buildOrderTypeSelector() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (enableDineIn)
              ChoiceChip(
                label: const Text('Dine-In'),
                selected: selectedOrderType == 'Dine-In',
                onSelected: (s) => setState(() => selectedOrderType = 'Dine-In'),
              ),
            const SizedBox(width: 6),
            if (enableTakeaway)
              ChoiceChip(
                label: const Text('Takeaway'),
                selected: selectedOrderType == 'Takeaway',
                onSelected: (s) => setState(() => selectedOrderType = 'Takeaway'),
              ),
            const SizedBox(width: 6),
            if (enableDelivery)
              ChoiceChip(
                label: const Text('Delivery'),
                selected: selectedOrderType == 'Delivery',
                onSelected: (s) => setState(() => selectedOrderType = 'Delivery'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuGrid({required int crossAxisCount}) {
    return FutureBuilder<List<MenuItem>>(
      future: _menuItemsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

        final items = snapshot.data!;
        return GridView.builder(
          padding: const EdgeInsets.all(8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            childAspectRatio: 1.1,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return Card(
              elevation: 3,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              color: item.inStock ? Colors.orange.shade50 : Colors.grey.shade300,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: item.inStock ? () => widget.onAddToCart(item) : null,
                child: Padding(
                  padding: const EdgeInsets.all(6.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(item.icon, style: const TextStyle(fontSize: 32)),
                      const SizedBox(height: 4),
                      Text(
                        widget.isUrdu && item.nameUr.isNotEmpty ? item.nameUr : item.nameEn,
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      FittedBox(
                        child: Text(
                          item.inStock ? 'Rs. ${item.price.toStringAsFixed(0)}' : 'OUT OF STOCK',
                          style: TextStyle(
                            fontSize: 14,
                            color: item.inStock ? Theme.of(context).colorScheme.primary : Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showCheckoutDialog(BuildContext context) {
    if (selectedOrderType == 'Delivery' && mobileCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mobile number is required for Delivery orders!')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Payment Method & Options'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.check_circle, size: 32, color: Colors.green),
              title: const Text('PAID (Cash)'),
              subtitle: const Text('Save transaction to record'),
              onTap: () => _choosePrintOrSave(ctx, 'Cash', true),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code, size: 32, color: Colors.blue),
              title: const Text('PAID (Online / EasyPaisa / JazzCash)'),
              subtitle: const Text('Save online transfer entry'),
              onTap: () => _choosePrintOrSave(ctx, 'Online', true),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.cancel, size: 32, color: Colors.red),
              title: const Text('UNPAID / UDHAR'),
              subtitle: const Text('Record as uncollected balance'),
              onTap: () => _choosePrintOrSave(ctx, 'Unpaid', false),
            ),
          ],
        ),
      ),
    );
  }

  void _choosePrintOrSave(BuildContext parentContext, String method, bool isPaid) {
    Navigator.pop(parentContext);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save or Print Bill?'),
        content: const Text('Choose whether to only save the sale or print the receipt.'),
        actions: [
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
            onPressed: () async {
              Navigator.pop(ctx);
              await _completePayment(method, isPaid, printReceipt: false);
            },
            icon: const Icon(Icons.save, color: Colors.white),
            label: const Text('Save Only', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () async {
              Navigator.pop(ctx);
              await _completePayment(method, isPaid, printReceipt: true);
            },
            icon: const Icon(Icons.print, color: Colors.white),
            label: const Text('Pay & Print', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _completePayment(String method, bool isPaid, {required bool printReceipt}) async {
    final itemsForReceipt = widget.cart
        .map((item) => CartItem(item: item.item, quantity: item.quantity, customPrice: item.customPrice))
        .toList();
    final amountToSave = grandTotal;
    final customerMobile = mobileCtrl.text.trim();
    final customerAddress = addressCtrl.text.trim();
    final savedOrderType = selectedOrderType;

    try {
      final billNo = await DatabaseHelper.instance.processSale(
        cartItems: itemsForReceipt,
        paymentMethod: method,
        tokenNo: widget.tokenNo,
        orderType: selectedOrderType,
        isPaid: isPaid,
        finalTotal: amountToSave,
        mobile: customerMobile.isNotEmpty ? customerMobile : null,
        address: customerAddress.isNotEmpty ? customerAddress : null,
      );

      if (!mounted) return;

      if (printReceipt) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => ReceiptPreviewModal(
            cartItems: itemsForReceipt,
            total: amountToSave,
            billNo: billNo,
            paymentMethod: method,
            tokenNo: widget.tokenNo,
            isPaid: isPaid,
            orderType: savedOrderType,
            mobile: customerMobile,
            isUrdu: widget.isUrdu,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transaction $billNo saved successfully!'), backgroundColor: Colors.green),
        );
      }

      widget.onCheckoutSuccess(savedOrderType);
      mobileCtrl.clear();
      addressCtrl.clear();
      discount = 0;
      discountCtrl.clear();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save sale: $e'), backgroundColor: Colors.red),
      );
    }
  }
}

/* ============================================================================
 * VIEW 2: TABLES VIEW
 * ========================================================================= */
class TablesView extends StatelessWidget {
  final bool isUrdu;
  final List<OrderToken> tokens;
  final Function(OrderToken) onSelectToken;

  const TablesView({super.key, required this.isUrdu, required this.tokens, required this.onSelectToken});

  @override
  Widget build(BuildContext context) {
    final tables = ['Table 1', 'Table 2', 'Table 3', 'Table 4', 'Table 5', 'Takeaway'];

    return LayoutBuilder(
      builder: (context, constraints) {
        int columns = constraints.maxWidth < 600 ? 2 : 3;
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            childAspectRatio: 1.2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: tables.length,
          itemBuilder: (context, index) {
            final tableName = tables[index];
            final openCount = tokens.where((t) => t.tableName == tableName).length;

            return Card(
              elevation: 3,
              color: openCount > 0 ? Colors.amber.shade100 : Colors.green.shade50,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(tableName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Badge(
                          label: Text('$openCount Open', style: const TextStyle(fontSize: 12)),
                          backgroundColor: openCount > 0 ? Colors.orange : Colors.green,
                        ),
                      ],
                    ),
                    Text(openCount > 0 ? '$openCount Active' : 'Available', style: const TextStyle(fontSize: 14)),
                    if (openCount > 0)
                      ...tokens.where((t) => t.tableName == tableName).map((token) => OutlinedButton(onPressed: () => onSelectToken(token), child: Text('${token.tokenNo} · Rs. ${token.total.toStringAsFixed(0)}', overflow: TextOverflow.ellipsis))),
                    ElevatedButton(
                      onPressed: () {
                        final existingNumbers = tokens.where((t) => t.tableName == tableName).map((t) => t.tokenNo).toSet();
                        var sequence = 0;
                        String tokenNo;
                        do { tokenNo = 'T${index + 1}-${DateTime.now().millisecondsSinceEpoch}'; sequence++; } while (existingNumbers.contains(tokenNo));
                        final newToken = OrderToken(
                          id: DateTime.now().microsecondsSinceEpoch.toString(),
                          tokenNo: tokenNo,
                          tableName: tableName,
                          items: [],
                          timeSeated: DateTime.now(),
                        );
                        onSelectToken(newToken);
                      },
                      child: const Text('+ New Customer', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/* ============================================================================
 * VIEW 3: MENU MANAGEMENT
 * ========================================================================= */
class MenuManagementView extends StatefulWidget {
  final bool isUrdu;

  const MenuManagementView({super.key, required this.isUrdu});

  @override
  State<MenuManagementView> createState() => _MenuManagementViewState();
}

class _MenuManagementViewState extends State<MenuManagementView> {
  late Future<List<MenuItem>> _menuFuture;

  @override
  void initState() {
    super.initState();
    _refreshMenu();
  }

  void _refreshMenu() {
    setState(() {
      _menuFuture = DatabaseHelper.instance.getMenuItems();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEditItemDialog(context),
        label: const Text('Add Item'),
        icon: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<MenuItem>>(
        future: _menuFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final items = snapshot.data!;
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Text(item.icon, style: const TextStyle(fontSize: 28)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.nameEn,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text('Rs. ${item.price.toStringAsFixed(0)} | ${item.inStock ? "In Stock" : "Out of Stock"}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                      ),
                      Switch(
                        value: item.inStock,
                        onChanged: (val) async {
                          await DatabaseHelper.instance.updateMenuItem(MenuItem(
                            id: item.id,
                            nameEn: item.nameEn,
                            nameUr: item.nameUr,
                            price: item.price,
                            icon: item.icon,
                            inStock: val,
                          ));
                          _refreshMenu();
                        },
                      ),
                      IconButton(
                        tooltip: 'Configure stock recipe',
                        icon: const Icon(Icons.science, color: Colors.deepPurple, size: 20),
                        onPressed: () => _showRecipeDialog(item.id!, item.nameEn),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blue, size: 20),
                        onPressed: () => _showAddEditItemDialog(context, item: item),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Delete menu item?'), content: Text('Delete ${item.nameEn} and its recipe?'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'))]));
                          if (confirmed != true) return;
                          await DatabaseHelper.instance.deleteMenuItem(item.id!);
                          if (mounted) _refreshMenu();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showAddEditItemDialog(BuildContext context, {MenuItem? item}) {
    final nameEnCtrl = TextEditingController(text: item?.nameEn ?? '');
    final nameUrCtrl = TextEditingController(text: item?.nameUr ?? '');
    final priceCtrl = TextEditingController(text: item != null ? item.price.toString() : '');
    final iconCtrl = TextEditingController(text: item?.icon ?? '🍽️');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null ? 'Add Menu Item' : 'Edit Menu Item'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameEnCtrl, decoration: const InputDecoration(labelText: 'Item Name (English)')),
            TextField(controller: nameUrCtrl, decoration: const InputDecoration(labelText: 'Item Name (Urdu)')), 
            TextField(controller: priceCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price (Rs.)')),
            TextField(controller: iconCtrl, decoration: const InputDecoration(labelText: 'Emoji Icon')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newItem = MenuItem(
                id: item?.id,
                nameEn: nameEnCtrl.text,
                nameUr: nameUrCtrl.text.isNotEmpty ? nameUrCtrl.text : nameEnCtrl.text,
                price: double.tryParse(priceCtrl.text) ?? 0,
                icon: iconCtrl.text,
                inStock: item?.inStock ?? true,
              );

              if (nameEnCtrl.text.trim().isEmpty || (double.tryParse(priceCtrl.text) ?? 0) < 0) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid item name and non-negative price.')));
                return;
              }
              int? createdId = item?.id;
              if (item == null) {
                createdId = await DatabaseHelper.instance.addMenuItem(newItem);
              } else {
                await DatabaseHelper.instance.updateMenuItem(newItem);
              }

              if (!mounted) return;
              Navigator.pop(ctx);
              _refreshMenu();
              if (item == null && createdId != null) {
                await _showRecipeDialog(createdId, newItem.nameEn);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/* ============================================================================
 * VIEW 4: INVENTORY VIEW
 * ========================================================================= */
class InventoryView extends StatefulWidget {
  final bool isUrdu;

  const InventoryView({super.key, required this.isUrdu});

  @override
  State<InventoryView> createState() => _InventoryViewState();
}

class _InventoryViewState extends State<InventoryView> {
  late Future<List<InventoryItem>> _inventoryFuture;

  @override
  void initState() {
    super.initState();
    _refreshStock();
  }

  void _refreshStock() {
    setState(() {
      _inventoryFuture = DatabaseHelper.instance.getInventory();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddStockDialog(context),
        label: const Text('Add Material'),
        icon: const Icon(Icons.add_box),
      ),
      body: FutureBuilder<List<InventoryItem>>(
        future: _inventoryFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final items = snapshot.data!;
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final isLow = item.stockQty < 20;

              return Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.inventory_2,
                        color: isLow ? Colors.red : Colors.green,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              isLow ? 'Low Stock Warning!' : 'Stock Available',
                              style: TextStyle(fontSize: 12, color: isLow ? Colors.red : Colors.grey.shade700),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${item.stockQty.toStringAsFixed(1)} ${item.unit}',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: isLow ? Colors.red : Colors.black),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle, color: Colors.green, size: 24),
                        onPressed: () => _showStockInDialog(context, item),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_forever, color: Colors.red, size: 24),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Delete inventory item?'), content: Text('Delete ${item.name} and remove it from all recipes?'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'))]));
                          if (confirmed != true) return;
                          await DatabaseHelper.instance.deleteInventoryItem(item.id!);
                          if (mounted) _refreshStock();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showStockInDialog(BuildContext context, InventoryItem item) {
    final qtyCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Stock-In: ${item.name}'),
        content: TextField(
          controller: qtyCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Add Quantity'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              double added = double.tryParse(qtyCtrl.text) ?? 0;
              await DatabaseHelper.instance.updateStockQty(item.id!, item.stockQty + added);
              if (!mounted) return;
              Navigator.pop(ctx);
              _refreshStock();
            },
            child: const Text('Add Stock'),
          ),
        ],
      ),
    );
  }

  void _showAddStockDialog(BuildContext context) {
    final nameCtrl = TextEditingController();
    final qtyCtrl = TextEditingController();
    final unitCtrl = TextEditingController(text: 'pcs');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add New Material'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Material Name')),
            TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Initial Quantity')),
            TextField(controller: unitCtrl, decoration: const InputDecoration(labelText: 'Unit (pcs, kg, liters)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              await DatabaseHelper.instance.addInventoryItem(InventoryItem(
                name: nameCtrl.text,
                stockQty: double.tryParse(qtyCtrl.text) ?? 0,
                unit: unitCtrl.text,
              ));
              if (!mounted) return;
              Navigator.pop(ctx);
              _refreshStock();
            },
            child: const Text('Save Material'),
          ),
        ],
      ),
    );
  }
}

/* ============================================================================
 * VIEW 5: VYAPAR-STYLE TRANSACTIONS & KHATA LEDGER
 * ========================================================================= */
class ReportsAndSalesHistoryView extends StatefulWidget {
  final bool isUrdu;

  const ReportsAndSalesHistoryView({super.key, required this.isUrdu});

  @override
  State<ReportsAndSalesHistoryView> createState() => _ReportsAndSalesHistoryViewState();
}

class _ReportsAndSalesHistoryViewState extends State<ReportsAndSalesHistoryView> {
  late Future<List<SaleRecord>> _salesFuture;
  String searchFilter = '';
  String paymentFilter = 'All';

  @override
  void initState() {
    super.initState();
    _refreshSales();
  }

  void _refreshSales() {
    setState(() {
      _salesFuture = DatabaseHelper.instance.getAllSales();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: FutureBuilder<List<SaleRecord>>(
        future: _salesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final allSales = snapshot.data!;

          final sales = allSales.where((s) {
            bool matchesSearch = searchFilter.isEmpty ||
                s.billNo.toLowerCase().contains(searchFilter.toLowerCase()) ||
                (s.customerMobile != null && s.customerMobile!.contains(searchFilter));

            bool matchesFilter = true;
            if (paymentFilter == 'Paid') matchesFilter = s.isPaid;
            if (paymentFilter == 'Unpaid') matchesFilter = !s.isPaid;

            return matchesSearch && matchesFilter;
          }).toList();

          final double totalPaidSales = allSales.where((s) => s.isPaid).fold(0, (sum, s) => sum + s.totalAmount);
          final double totalUnpaidSales = allSales.where((s) => !s.isPaid).fold(0, (sum, s) => sum + s.totalAmount);

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    _buildSummaryCard('Paid Sales', 'Rs. ${totalPaidSales.toStringAsFixed(0)}', Colors.green),
                    _buildSummaryCard('Udhar / Receivables', 'Rs. ${totalUnpaidSales.toStringAsFixed(0)}', Colors.red),
                    _buildSummaryCard('Total Bills', '${allSales.length}', Colors.blue),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: 'Search Mobile / Bill #',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (val) => setState(() => searchFilter = val),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: paymentFilter,
                      items: const [
                        DropdownMenuItem(value: 'All', child: Text('All Bills')),
                        DropdownMenuItem(value: 'Paid', child: Text('Paid Only')),
                        DropdownMenuItem(value: 'Unpaid', child: Text('Udhar Only')),
                      ],
                      onChanged: (v) => setState(() => paymentFilter = v!),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: sales.isEmpty
                    ? const Center(child: Text('No transactions recorded yet'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: sales.length,
                        itemBuilder: (context, index) {
                          final sale = sales[index];
                          return Card(
                            elevation: 2,
                            child: ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: sale.isPaid ? Colors.green : Colors.red,
                                child: Icon(sale.isPaid ? Icons.check : Icons.priority_high, color: Colors.white, size: 16),
                              ),
                              title: Text(
                                '${sale.billNo} | ${sale.tokenNo} (${sale.orderType})',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text('Items: ${sale.itemsSummary}\nMobile: ${sale.customerMobile ?? "N/A"}'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'Rs. ${sale.totalAmount.toStringAsFixed(0)}',
                                    style: TextStyle(fontWeight: FontWeight.bold, color: sale.isPaid ? Colors.green : Colors.red),
                                  ),
                                  const SizedBox(width: 4),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: sale.isPaid ? Colors.grey : Colors.green,
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                    ),
                                    onPressed: () async {
                                      await DatabaseHelper.instance.updatePaymentStatus(sale.id!, !sale.isPaid);
                                      _refreshSales();
                                    },
                                    child: Text(
                                      sale.isPaid ? 'Mark Unpaid' : 'Mark Paid',
                                      style: const TextStyle(color: Colors.white, fontSize: 11),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.edit, color: Colors.blue, size: 20),
                                    onPressed: () => _showEditTransactionDialog(context, sale),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                    onPressed: () async {
                                      final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Delete sale record?'), content: Text('Delete ${sale.billNo}? Stock deducted by this sale will be restored.'), actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'))]));
                                      if (confirmed != true) return;
                                      await DatabaseHelper.instance.deleteSale(sale.id!);
                                      if (mounted) _refreshSales();
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showEditTransactionDialog(BuildContext context, SaleRecord sale) {
    final amountCtrl = TextEditingController(text: sale.totalAmount.toString());
    final mobileCtrl = TextEditingController(text: sale.customerMobile ?? '');
    final addressCtrl = TextEditingController(text: sale.customerAddress ?? '');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit Transaction: ${sale.billNo}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Total Amount (Rs.)')),
            TextField(controller: mobileCtrl, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Customer Mobile')),
            TextField(controller: addressCtrl, decoration: const InputDecoration(labelText: 'Delivery Address')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              double newAmt = double.tryParse(amountCtrl.text) ?? sale.totalAmount;
              await DatabaseHelper.instance.updateSaleDetails(sale.id!, newAmt, mobileCtrl.text, addressCtrl.text);
              if (!mounted) return;
              Navigator.pop(ctx);
              _refreshSales();
            },
            child: const Text('Update Transaction'),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(String title, String value, Color color) {
    return Expanded(
      child: Card(
        color: color.withValues(alpha: 0.1),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              Text(title, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 2),
              FittedBox(
                child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ============================================================================
 * VIEW 6: SETTINGS VIEW
 * ========================================================================= */
class SettingsView extends StatefulWidget {
  final bool isUrdu;
  final VoidCallback onSettingsSaved;

  const SettingsView({super.key, required this.isUrdu, required this.onSettingsSaved});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final nameCtrl = TextEditingController();
  final addressCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();
  final accountInfoCtrl = TextEditingController();

  bool enableDineIn = true;
  bool enableTakeaway = true;
  bool enableDelivery = true;

  @override
  void initState() {
    super.initState();
    _loadValues();
  }

  void _loadValues() async {
    nameCtrl.text = await DatabaseHelper.instance.getSetting('shop_name', defaultValue: 'Bismillah Shereen Mehal Samosa POS');
    addressCtrl.text = await DatabaseHelper.instance.getSetting('shop_address', defaultValue: 'Main Chowk, Layyah');
    if (!mounted) return;
    phoneCtrl.text = await DatabaseHelper.instance.getSetting('shop_phone', defaultValue: '+92 300 1234567');
    accountInfoCtrl.text = await DatabaseHelper.instance.getSetting('payment_account_info', defaultValue: 'EasyPaisa/JazzCash: 03001234567');

    String d = await DatabaseHelper.instance.getSetting('enable_dine_in', defaultValue: '1');
    String t = await DatabaseHelper.instance.getSetting('enable_takeaway', defaultValue: '1');
    String del = await DatabaseHelper.instance.getSetting('enable_delivery', defaultValue: '1');

    if (!mounted) return;
    setState(() {
      enableDineIn = d == '1';
      enableTakeaway = t == '1';
      enableDelivery = del == '1';
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Shop Profile & Settings', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Shop Name', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(controller: addressCtrl, decoration: const InputDecoration(labelText: 'Address', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone Number', border: OutlineInputBorder())),
        const SizedBox(height: 10),
        TextField(
          controller: accountInfoCtrl,
          decoration: const InputDecoration(labelText: 'EasyPaisa / JazzCash Account Info', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),

        const Text('Order Types', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        SwitchListTile(
          title: const Text('Dine-In Options'),
          value: enableDineIn,
          onChanged: (v) => setState(() => enableDineIn = v),
        ),
        SwitchListTile(
          title: const Text('Takeaway Options'),
          value: enableTakeaway,
          onChanged: (v) => setState(() => enableTakeaway = v),
        ),
        SwitchListTile(
          title: const Text('Delivery Options'),
          value: enableDelivery,
          onChanged: (v) => setState(() => enableDelivery = v),
        ),
        const SizedBox(height: 16),

        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, padding: const EdgeInsets.symmetric(vertical: 14)),
          onPressed: () async {
            String dbPath = await DatabaseHelper.instance.getDatabasePath();
            await SharePlus.instance.share(ShareParams(files: [XFile(dbPath)], text: 'Bismillah Samosa POS Database Backup'));
          },
          icon: const Icon(Icons.backup, color: Colors.white),
          label: const Text('Backup Database File', style: TextStyle(color: Colors.white, fontSize: 16)),
        ),
        const SizedBox(height: 10),

        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(vertical: 14)),
          onPressed: () async {
            await DatabaseHelper.instance.setSetting('shop_name', nameCtrl.text);
            await DatabaseHelper.instance.setSetting('shop_address', addressCtrl.text);
            await DatabaseHelper.instance.setSetting('shop_phone', phoneCtrl.text);
            await DatabaseHelper.instance.setSetting('payment_account_info', accountInfoCtrl.text);
            await DatabaseHelper.instance.setSetting('enable_dine_in', enableDineIn ? '1' : '0');
            await DatabaseHelper.instance.setSetting('enable_takeaway', enableTakeaway ? '1' : '0');
            await DatabaseHelper.instance.setSetting('enable_delivery', enableDelivery ? '1' : '0');

            widget.onSettingsSaved();

            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings Saved Successfully!')));
          },
          icon: const Icon(Icons.save, color: Colors.white),
          label: const Text('Save Settings', style: TextStyle(color: Colors.white, fontSize: 16)),
        ),
      ],
    );
  }
}

/* ============================================================================
 * THERMAL RECEIPT MODAL
 * ========================================================================= */
class ReceiptPreviewModal extends StatefulWidget {
  final List<CartItem> cartItems;
  final double total;
  final String paymentMethod;
  final String billNo;
  final String tokenNo;
  final bool isPaid;
  final String orderType;
  final String mobile;
  final bool isUrdu;

  const ReceiptPreviewModal({
    super.key,
    required this.cartItems,
    required this.total,
    required this.paymentMethod,
    required this.billNo,
    required this.tokenNo,
    required this.isPaid,
    required this.orderType,
    required this.mobile,
    required this.isUrdu,
  });

  @override
  State<ReceiptPreviewModal> createState() => _ReceiptPreviewModalState();
}

class _ReceiptPreviewModalState extends State<ReceiptPreviewModal> {
  final GlobalKey _receiptKey = GlobalKey();
  String shopName = 'Bismillah Shereen Mehal Samosa POS';
  String shopAddress = 'Main Chowk, Layyah';
  String shopPhone = '+92 300 1234567';
  String accountInfo = 'EasyPaisa/JazzCash: 03001234567';

  @override
  void initState() {
    super.initState();
    _loadReceiptSettings();
  }

  void _loadReceiptSettings() async {
    shopName = await DatabaseHelper.instance.getSetting('shop_name', defaultValue: 'Bismillah Shereen Mehal Samosa POS');
    shopAddress = await DatabaseHelper.instance.getSetting('shop_address', defaultValue: 'Main Chowk, Layyah');
    shopPhone = await DatabaseHelper.instance.getSetting('shop_phone', defaultValue: '+92 300 1234567');
    accountInfo = await DatabaseHelper.instance.getSetting('payment_account_info', defaultValue: 'EasyPaisa/JazzCash: 03001234567');
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _shareReceiptImage() async {
    try {
      RenderRepaintBoundary boundary = _receiptKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      var byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      var pngBytes = byteData!.buffer.asUint8List();

      final tempDir = await getTemporaryDirectory();
      final file = await File('${tempDir.path}/receipt_${DateTime.now().millisecondsSinceEpoch}.png').create();
      await file.writeAsBytes(pngBytes);

      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], text: 'Receipt from $shopName'));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to share image: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final billNo = widget.billNo;

    return Container(
      padding: const EdgeInsets.all(16),
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        children: [
          const Text('Thermal Receipt Preview', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              child: RepaintBoundary(
                key: _receiptKey,
                child: Container(
                  width: 280,
                  padding: const EdgeInsets.all(12),
                  color: Colors.white,
                  child: Column(
                    children: [
                      Text(shopName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                      Text(shopAddress, style: const TextStyle(fontSize: 12)),
                      Text('Ph: $shopPhone', style: const TextStyle(fontSize: 12)),
                      const Divider(thickness: 2),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Token: ${widget.tokenNo}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          Text('Type: ${widget.orderType}', style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                      if (widget.mobile.isNotEmpty) Text('Customer: ${widget.mobile}', style: const TextStyle(fontSize: 12)),
                      const Divider(),

                      ...widget.cartItems.map((c) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('${c.item.nameEn} x${c.quantity}', style: const TextStyle(fontSize: 12)),
                                Text('Rs. ${c.total.toStringAsFixed(0)}', style: const TextStyle(fontSize: 12)),
                              ],
                            ),
                          )),
                      const Divider(thickness: 2),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('GRAND TOTAL:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                          Text('Rs. ${widget.total.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        ],
                      ),

                      Container(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                        color: widget.isPaid ? Colors.green : Colors.red,
                        child: Text(
                          widget.isPaid ? 'PAID' : 'UNPAID / UDHAR',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),

                      const SizedBox(height: 8),
                      QrImageView(
                        data: accountInfo,
                        version: QrVersions.auto,
                        size: 100.0,
                      ),
                      Text(accountInfo, style: const TextStyle(fontSize: 10), textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      BarcodeWidget(
                        barcode: Barcode.code128(),
                        data: billNo,
                        height: 30,
                        width: 150,
                      ),
                      const SizedBox(height: 6),
                      const Text('Thank you! Visit again.', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, minimumSize: const Size(0, 44)),
                  onPressed: _shareReceiptImage,
                  icon: const Icon(Icons.share, color: Colors.white, size: 18),
                  label: const Text('Share Image (WhatsApp)', style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, minimumSize: const Size(0, 44)),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check, color: Colors.white, size: 18),
                  label: const Text('Done', style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
