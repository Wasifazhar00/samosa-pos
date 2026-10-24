import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:barcode_widget/barcode_widget.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Desktop SQLite Initialization
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
        nameEn: map['name_en'],
        nameUr: map['name_ur'],
        price: (map['price'] as num).toDouble(),
        icon: map['icon'],
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
        name: map['name'],
        stockQty: (map['stock_qty'] as num).toDouble(),
        unit: map['unit'],
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
 * DATABASE & SETTINGS HELPER
 * ========================================================================= */
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('bismillah_samosa_pos.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 2,
      onCreate: _createDB,
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
        bill_no TEXT,
        token_no TEXT,
        total_amount REAL,
        payment_method TEXT,
        created_at TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    await _seedDefaults(db);
  }

  Future<void> _seedDefaults(Database db) async {
    // Default Settings
    await db.insert('settings', {'key': 'shop_name', 'value': 'Bismillah Shereen Mehal Samosa POS'});
    await db.insert('settings', {'key': 'shop_address', 'value': 'Main Chowk, Layyah'});
    await db.insert('settings', {'key': 'shop_phone', 'value': '+92 300 1234567'});
    await db.insert('settings', {'key': 'upi_id', 'value': 'bismillahsamosa@easypaisa'});
    await db.insert('settings', {'key': 'admin_pin', 'value': '1234'});
    await db.insert('settings', {'key': 'receipt_footer', 'value': 'Thank you! Visit Bismillah Shereen Mehal again.'});

    // Seed Inventory
    int patiId = await db.insert('inventory', {'name': 'Samosa Pati', 'stock_qty': 500, 'unit': 'pcs'});
    int chanaId = await db.insert('inventory', {'name': 'Chana', 'stock_qty': 100, 'unit': 'servings'});
    int chatniId = await db.insert('inventory', {'name': 'Chatni', 'stock_qty': 100, 'unit': 'servings'});
    int chickenId = await db.insert('inventory', {'name': 'Chicken Filling', 'stock_qty': 50, 'unit': 'kg'});
    int alooId = await db.insert('inventory', {'name': 'Aloo Filling', 'stock_qty': 50, 'unit': 'kg'});
    int cokeId = await db.insert('inventory', {'name': 'Cold Drink (Coke)', 'stock_qty': 40, 'unit': 'bottles'});

    // Seed Menu
    int m1 = await db.insert('menu', {'name_en': 'Chicken Samosa', 'name_ur': 'چکن سموسہ', 'price': 50, 'icon': '🍗', 'in_stock': 1});
    int m2 = await db.insert('menu', {'name_en': 'Aloo Samosa', 'name_ur': 'آلو سموسہ', 'price': 30, 'icon': '🥔', 'in_stock': 1});
    int m3 = await db.insert('menu', {'name_en': 'Single Plate', 'name_ur': 'سنگل پلیٹ', 'price': 80, 'icon': '🍽️', 'in_stock': 1});
    int m4 = await db.insert('menu', {'name_en': 'Double Plate', 'name_ur': 'ڈبل پلیٹ', 'price': 140, 'icon': '🍱', 'in_stock': 1});
    int m5 = await db.insert('menu', {'name_en': 'Cold Drink', 'name_ur': 'کولڈ ڈرنک', 'price': 70, 'icon': '🥤', 'in_stock': 1});

    // Seed Recipes (BOM)
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

  // --- MENU MANAGEMENT CRUD ---
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
    return await db.delete('menu', where: 'id = ?', whereArgs: [id]);
  }

  // --- INVENTORY MANAGEMENT CRUD ---
  Future<List<InventoryItem>> getInventory() async {
    final db = await instance.database;
    final result = await db.query('inventory');
    return result.map((json) => InventoryItem.fromMap(json)).toList();
  }

  Future<int> addInventoryItem(InventoryItem item) async {
    final db = await instance.database;
    return await db.insert('inventory', item.toMap());
  }

  Future<int> updateStockQty(int id, double newQty) async {
    final db = await instance.database;
    return await db.rawUpdate('UPDATE inventory SET stock_qty = ? WHERE id = ?', [newQty, id]);
  }

  // --- SETTINGS CRUD ---
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
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Process Sales & Deduct Stock
  Future<void> processSale(List<CartItem> cartItems, String paymentMethod, String tokenNo) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      double grandTotal = 0;

      for (var cart in cartItems) {
        grandTotal += cart.total;

        final recipes = await txn.query(
          'recipes',
          where: 'menu_id = ?',
          whereArgs: [cart.item.id],
        );

        for (var rule in recipes) {
          int invId = rule['inventory_id'] as int;
          double reqQty = (rule['required_qty'] as num).toDouble();
          double totalDeduction = reqQty * cart.quantity;

          await txn.rawUpdate(
            'UPDATE inventory SET stock_qty = stock_qty - ? WHERE id = ?',
            [totalDeduction, invId],
          );
        }
      }

      await txn.insert('sales', {
        'bill_no': 'INV-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}',
        'token_no': tokenNo,
        'total_amount': grandTotal,
        'payment_method': paymentMethod,
        'created_at': DateTime.now().toIso8601String(),
      });
    });
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
 * MAIN SCREEN (NAV BARS & TABS)
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
  }

  void _loadSettings() async {
    String name = await DatabaseHelper.instance.getSetting('shop_name', defaultValue: 'Bismillah Shereen Mehal Samosa POS');
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
          widget.isUrdu ? 'بسم اللہ شیریں محل سموسہ POS' : shopName,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 20),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
              onPressed: widget.onToggleLanguage,
              icon: const Icon(Icons.language, color: Colors.black),
              label: Text(
                widget.isUrdu ? 'English' : 'اردو',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          PosTerminalView(
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
            onCheckoutSuccess: () => setState(() => cart.clear()),
          ),
          TablesView(
            isUrdu: widget.isUrdu,
            tokens: activeTokens,
            onSelectToken: (token) {
              setState(() {
                cart = List.from(token.items);
                activeTable = token.tableName;
                currentTokenNo = token.tokenNo;
                _selectedIndex = 0;
              });
            },
          ),
          MenuManagementView(isUrdu: widget.isUrdu),
          InventoryView(isUrdu: widget.isUrdu),
          ReportsView(isUrdu: widget.isUrdu),
          SettingsView(
            isUrdu: widget.isUrdu,
            onSettingsSaved: _loadSettings,
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (idx) => setState(() => _selectedIndex = idx),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.point_of_sale, size: 28),
            label: widget.isUrdu ? 'آرڈر (POS)' : 'POS Order',
          ),
          NavigationDestination(
            icon: const Icon(Icons.table_restaurant, size: 28),
            label: widget.isUrdu ? 'ٹیبلز' : 'Tables',
          ),
          NavigationDestination(
            icon: const Icon(Icons.restaurant_menu, size: 28),
            label: widget.isUrdu ? 'مینو (Menu)' : 'Menu Edit',
          ),
          NavigationDestination(
            icon: const Icon(Icons.inventory, size: 28),
            label: widget.isUrdu ? 'سٹاک (Stock)' : 'Inventory',
          ),
          NavigationDestination(
            icon: const Icon(Icons.bar_chart, size: 28),
            label: widget.isUrdu ? 'رپورٹس' : 'Reports',
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings, size: 28),
            label: widget.isUrdu ? 'سیٹنگز' : 'Settings',
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
  final VoidCallback onCheckoutSuccess;

  const PosTerminalView({
    super.key,
    required this.isUrdu,
    required this.cart,
    required this.tokenNo,
    required this.tableName,
    required this.onAddToCart,
    required this.onClearCart,
    required this.onCheckoutSuccess,
  });

  @override
  State<PosTerminalView> createState() => _PosTerminalViewState();
}

class _PosTerminalViewState extends State<PosTerminalView> {
  late Future<List<MenuItem>> _menuItemsFuture;
  double discount = 0;

  @override
  void initState() {
    super.initState();
    _refreshMenu();
  }

  void _refreshMenu() {
    setState(() {
      _menuItemsFuture = DatabaseHelper.instance.getMenuItems();
    });
  }

  double get subTotal => widget.cart.fold(0, (sum, item) => sum + item.total);
  double get grandTotal => subTotal - discount < 0 ? 0 : subTotal - discount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Left Menu Grid
        Expanded(
          flex: 3,
          child: FutureBuilder<List<MenuItem>>(
            future: _menuItemsFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

              final items = snapshot.data!;
              return GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 1.1,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    color: item.inStock ? Colors.orange.shade50 : Colors.grey.shade300,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: item.inStock ? () => widget.onAddToCart(item) : null,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(item.icon, style: const TextStyle(fontSize: 44)),
                          const SizedBox(height: 6),
                          Text(
                            widget.isUrdu ? item.nameUr : item.nameEn,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            item.inStock ? 'Rs. ${item.price.toStringAsFixed(0)}' : 'OUT OF STOCK',
                            style: TextStyle(
                              fontSize: 16,
                              color: item.inStock ? Theme.of(context).colorScheme.primary : Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),

        // Right Cart View
        Expanded(
          flex: 2,
          child: Card(
            margin: const EdgeInsets.all(8),
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: Colors.grey.shade200,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Token: ${widget.tokenNo}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Text('Table: ${widget.tableName}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),

                  Expanded(
                    child: widget.cart.isEmpty
                        ? Center(
                            child: Text(
                              widget.isUrdu ? 'کارٹ خالی ہے' : 'Cart is empty',
                              style: const TextStyle(fontSize: 18, color: Colors.grey),
                            ),
                          )
                        : ListView.separated(
                            itemCount: widget.cart.length,
                            separatorBuilder: (c, i) => const Divider(),
                            itemBuilder: (context, index) {
                              final cartItem = widget.cart[index];
                              return ListTile(
                                title: Text(
                                  widget.isUrdu ? cartItem.item.nameUr : cartItem.item.nameEn,
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                                subtitle: Text('Rs. ${cartItem.customPrice} x ${cartItem.quantity}'),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'Rs. ${cartItem.total.toStringAsFixed(0)}',
                                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.remove_circle, color: Colors.red),
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

                  // Discount Field
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(widget.isUrdu ? 'ڈسکانٹ:' : 'Discount:'),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                          onChanged: (v) => setState(() => discount = double.tryParse(v) ?? 0),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          widget.isUrdu ? 'کل رقم:' : 'TOTAL:',
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Rs. ${grandTotal.toStringAsFixed(0)}',
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.green),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: widget.onClearCart,
                          child: Text(
                            widget.isUrdu ? 'کینسل' : 'Cancel',
                            style: const TextStyle(color: Colors.white, fontSize: 18),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: widget.cart.isEmpty ? null : () => _showCheckoutDialog(context),
                          child: Text(
                            widget.isUrdu ? 'بل ادا کریں (Pay)' : 'Pay & Print',
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                          ),
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

  void _showCheckoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.isUrdu ? 'ادائیگی منتخب کریں' : 'Select Payment Method'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.money, size: 36, color: Colors.green),
              title: Text(widget.isUrdu ? 'نقد (Cash)' : 'Cash'),
              onTap: () {
                Navigator.pop(ctx);
                _completePayment('Cash');
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code, size: 36, color: Colors.blue),
              title: Text(widget.isUrdu ? 'آن لائن / EasyPaisa / UPI' : 'Online / EasyPaisa / UPI'),
              onTap: () {
                Navigator.pop(ctx);
                _completePayment('Online');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _completePayment(String method) async {
    await DatabaseHelper.instance.processSale(widget.cart, method, widget.tokenNo);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ReceiptPreviewModal(
        cartItems: List.from(widget.cart),
        total: grandTotal,
        paymentMethod: method,
        tokenNo: widget.tokenNo,
        isUrdu: widget.isUrdu,
      ),
    );

    widget.onCheckoutSuccess();
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

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 1.3,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: tables.length,
      itemBuilder: (context, index) {
        final tableName = tables[index];
        final openCount = tokens.where((t) => t.tableName == tableName).length;

        return Card(
          elevation: 4,
          color: openCount > 0 ? Colors.amber.shade100 : Colors.green.shade50,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(tableName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    Badge(
                      label: Text('$openCount Open', style: const TextStyle(fontSize: 14)),
                      backgroundColor: openCount > 0 ? Colors.orange : Colors.green,
                    ),
                  ],
                ),
                Text(
                  openCount > 0 ? '$openCount Active Customer(s)' : 'Available',
                  style: const TextStyle(fontSize: 16),
                ),
                ElevatedButton(
                  onPressed: () {
                    final newToken = OrderToken(
                      id: DateTime.now().toString(),
                      tokenNo: '${index + 1}-${String.fromCharCode(65 + openCount)}',
                      tableName: tableName,
                      items: [],
                      timeSeated: DateTime.now(),
                    );
                    onSelectToken(newToken);
                  },
                  child: Text(isUrdu ? '+ نیا کسٹمر' : '+ New Customer'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/* ============================================================================
 * VIEW 3: MENU MANAGEMENT VIEW (ADD / EDIT / DELETE)
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
        label: Text(widget.isUrdu ? 'نیا آئٹم شامل کریں' : 'Add New Menu Item'),
        icon: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<MenuItem>>(
        future: _menuFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final items = snapshot.data!;
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              return Card(
                child: ListTile(
                  leading: Text(item.icon, style: const TextStyle(fontSize: 32)),
                  title: Text('${item.nameEn} / ${item.nameUr}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  subtitle: Text('Price: Rs. ${item.price} | Status: ${item.inStock ? "In Stock" : "Out of Stock"}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                        icon: const Icon(Icons.edit, color: Colors.blue),
                        onPressed: () => _showAddEditItemDialog(context, item: item),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () async {
                          await DatabaseHelper.instance.deleteMenuItem(item.id!);
                          _refreshMenu();
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
    final iconCtrl = TextEditingController(text: item?.icon ?? '🥙');

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item == null ? 'Add Menu Item' : 'Edit Menu Item'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameEnCtrl, decoration: const InputDecoration(labelText: 'English Name')),
            TextField(controller: nameUrCtrl, decoration: const InputDecoration(labelText: 'Urdu Name')),
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
                nameUr: nameUrCtrl.text,
                price: double.tryParse(priceCtrl.text) ?? 0,
                icon: iconCtrl.text,
                inStock: item?.inStock ?? true,
              );

              if (item == null) {
                await DatabaseHelper.instance.addMenuItem(newItem);
              } else {
                await DatabaseHelper.instance.updateMenuItem(newItem);
              }

              if (!mounted) return;
              Navigator.pop(ctx);
              _refreshMenu();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/* ============================================================================
 * VIEW 4: INVENTORY VIEW (STOCK-IN & RAW MATERIALS)
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
        label: Text(widget.isUrdu ? 'نیا سٹاک شامل کریں' : 'Add Raw Material'),
        icon: const Icon(Icons.add_box),
      ),
      body: FutureBuilder<List<InventoryItem>>(
        future: _inventoryFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final items = snapshot.data!;
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final isLow = item.stockQty < 20;

              return Card(
                child: ListTile(
                  leading: Icon(
                    Icons.inventory_2,
                    color: isLow ? Colors.red : Colors.green,
                    size: 36,
                  ),
                  title: Text(item.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  subtitle: Text(isLow ? 'Low Stock Warning!' : 'Stock Available'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${item.stockQty.toStringAsFixed(1)} ${item.unit}',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isLow ? Colors.red : Colors.black),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add_circle, color: Colors.green, size: 30),
                        onPressed: () => _showStockInDialog(context, item),
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
        title: const Text('Add New Inventory Item'),
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
 * VIEW 5: REPORTS VIEW
 * ========================================================================= */
class ReportsView extends StatelessWidget {
  final bool isUrdu;

  const ReportsView({super.key, required this.isUrdu});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isUrdu ? 'آج کی کارکردگی (Day-End Z Report)' : 'Today\'s Z-Report Summary',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildReportCard('Total Sales', 'Rs. 12,450', Colors.green),
              _buildReportCard('Patis Consumed', '184 pcs', Colors.orange),
              _buildReportCard('Bills Count', '42 Orders', Colors.blue),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReportCard(String title, String value, Color color) {
    return Expanded(
      child: Card(
        color: color.withOpacity(0.1),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              Text(title, style: const TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/* ============================================================================
 * VIEW 6: SETTINGS VIEW (SHOP SETUP & CUSTOMIZATION)
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
  final upiCtrl = TextEditingController();
  final pinCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadValues();
  }

  void _loadValues() async {
    nameCtrl.text = await DatabaseHelper.instance.getSetting('shop_name', defaultValue: 'Bismillah Shereen Mehal Samosa POS');
    addressCtrl.text = await DatabaseHelper.instance.getSetting('shop_address', defaultValue: 'Main Chowk, Layyah');
    phoneCtrl.text = await DatabaseHelper.instance.getSetting('shop_phone', defaultValue: '+92 300 1234567');
    upiCtrl.text = await DatabaseHelper.instance.getSetting('upi_id', defaultValue: 'bismillahsamosa@easypaisa');
    pinCtrl.text = await DatabaseHelper.instance.getSetting('admin_pin', defaultValue: '1234');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          widget.isUrdu ? 'دکان کی تفصیلات' : 'Shop Profile & Settings',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Shop Name', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: addressCtrl, decoration: const InputDecoration(labelText: 'Address', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone Number', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: upiCtrl, decoration: const InputDecoration(labelText: 'UPI / EasyPaisa QR String', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: pinCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Admin Security PIN', border: OutlineInputBorder())),
        const SizedBox(height: 20),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
          onPressed: () async {
            await DatabaseHelper.instance.setSetting('shop_name', nameCtrl.text);
            await DatabaseHelper.instance.setSetting('shop_address', addressCtrl.text);
            await DatabaseHelper.instance.setSetting('shop_phone', phoneCtrl.text);
            await DatabaseHelper.instance.setSetting('upi_id', upiCtrl.text);
            await DatabaseHelper.instance.setSetting('admin_pin', pinCtrl.text);

            widget.onSettingsSaved();

            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Settings Saved Successfully!')),
            );
          },
          icon: const Icon(Icons.save, color: Colors.white),
          label: const Text('Save Settings', style: TextStyle(color: Colors.white, fontSize: 18)),
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
  final String tokenNo;
  final bool isUrdu;

  const ReceiptPreviewModal({
    super.key,
    required this.cartItems,
    required this.total,
    required this.paymentMethod,
    required this.tokenNo,
    required this.isUrdu,
  });

  @override
  State<ReceiptPreviewModal> createState() => _ReceiptPreviewModalState();
}

class _ReceiptPreviewModalState extends State<ReceiptPreviewModal> {
  String shopName = 'Bismillah Shereen Mehal Samosa POS';
  String shopAddress = 'Main Chowk, Layyah';
  String shopPhone = '+92 300 1234567';
  String upiId = 'bismillahsamosa@easypaisa';

  @override
  void initState() {
    super.initState();
    _loadReceiptSettings();
  }

  void _loadReceiptSettings() async {
    shopName = await DatabaseHelper.instance.getSetting('shop_name', defaultValue: 'Bismillah Shereen Mehal Samosa POS');
    shopAddress = await DatabaseHelper.instance.getSetting('shop_address', defaultValue: 'Main Chowk, Layyah');
    shopPhone = await DatabaseHelper.instance.getSetting('shop_phone', defaultValue: '+92 300 1234567');
    upiId = await DatabaseHelper.instance.getSetting('upi_id', defaultValue: 'bismillahsamosa@easypaisa');
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    String billNo = 'INV-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';

    return Container(
      padding: const EdgeInsets.all(24),
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        children: [
          const Text('Thermal Receipt Preview (58mm/80mm)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Divider(),
          Expanded(
            child: SingleChildScrollView(
              child: Container(
                width: 320,
                padding: const EdgeInsets.all(16),
                color: Colors.white,
                child: Column(
                  children: [
                    Text(shopName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                    Text(shopAddress),
                    Text('Ph: $shopPhone'),
                    const Divider(thickness: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Token: ${widget.tokenNo}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text('Bill: $billNo'),
                      ],
                    ),
                    const Divider(),
                    ...widget.cartItems.map((c) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${c.item.nameEn} x${c.quantity}'),
                              Text('Rs. ${c.total.toStringAsFixed(0)}'),
                            ],
                          ),
                        )),
                    const Divider(thickness: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('GRAND TOTAL:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                        Text('Rs. ${widget.total.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      ],
                    ),
                    Text('Payment: ${widget.paymentMethod}', style: const TextStyle(fontStyle: FontStyle.italic)),
                    const SizedBox(height: 12),
                    QrImageView(
                      data: 'upi://pay?pa=$upiId&pn=BismillahSamosa&am=${widget.total}',
                      version: QrVersions.auto,
                      size: 120.0,
                    ),
                    const Text('Scan to Pay (EasyPaisa / UPI)', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 12),
                    BarcodeWidget(
                      barcode: Barcode.code128(),
                      data: billNo,
                      height: 40,
                      width: 180,
                    ),
                    const SizedBox(height: 8),
                    const Text('Thank you! Visit again.', style: TextStyle(fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              minimumSize: const Size(double.infinity, 50),
            ),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.print, color: Colors.white),
            label: const Text('Print Receipt Now', style: TextStyle(color: Colors.white, fontSize: 18)),
          ),
        ],
      ),
    );
  }
}
