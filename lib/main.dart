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

  CartItem({required this.item, this.quantity = 1});

  double get total => item.price * quantity;
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
 * DATABASE & BOM SERVICE
 * ========================================================================= */
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('samosa_pos.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
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

    // Seed Defaults
    await _seedDefaults(db);
  }

  Future<void> _seedDefaults(Database db) async {
    // 1. Inventory Items
    int patiId = await db.insert('inventory', {'name': 'Samosa Pati', 'stock_qty': 500, 'unit': 'pcs'});
    int chanaId = await db.insert('inventory', {'name': 'Chana', 'stock_qty': 100, 'unit': 'servings'});
    int chatniId = await db.insert('inventory', {'name': 'Chatni', 'stock_qty': 100, 'unit': 'servings'});
    int chickenId = await db.insert('inventory', {'name': 'Chicken Filling', 'stock_qty': 50, 'unit': 'kg'});
    int alooId = await db.insert('inventory', {'name': 'Aloo Filling', 'stock_qty': 50, 'unit': 'kg'});
    int cokeId = await db.insert('inventory', {'name': 'Cold Drink (Coke)', 'stock_qty': 40, 'unit': 'bottles'});

    // 2. Menu Items
    int m1 = await db.insert('menu', {'name_en': 'Chicken Samosa', 'name_ur': 'چکن سموسہ', 'price': 50, 'icon': '🍗', 'in_stock': 1});
    int m2 = await db.insert('menu', {'name_en': 'Aloo Samosa', 'name_ur': 'آلو سموسہ', 'price': 30, 'icon': '🥔', 'in_stock': 1});
    int m3 = await db.insert('menu', {'name_en': 'Single Plate', 'name_ur': 'سنگل پلیٹ', 'price': 80, 'icon': '🍽️', 'in_stock': 1});
    int m4 = await db.insert('menu', {'name_en': 'Double Plate', 'name_ur': 'ڈبل پلیٹ', 'price': 140, 'icon': '🍱', 'in_stock': 1});
    int m5 = await db.insert('menu', {'name_en': 'Cold Drink', 'name_ur': 'کولڈ ڈرنک', 'price': 70, 'icon': '🥤', 'in_stock': 1});

    // 3. Recipes (Bill of Materials)
    // Single Samosas
    await db.insert('recipes', {'menu_id': m1, 'inventory_id': patiId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m1, 'inventory_id': chickenId, 'required_qty': 0.05});

    await db.insert('recipes', {'menu_id': m2, 'inventory_id': patiId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m2, 'inventory_id': alooId, 'required_qty': 0.05});

    // Single Plate = 1 Samosa Pati + Chana + Chatni
    await db.insert('recipes', {'menu_id': m3, 'inventory_id': patiId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m3, 'inventory_id': chanaId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m3, 'inventory_id': chatniId, 'required_qty': 1});

    // Double Plate = 2 Samosa Patis + Chana + Chatni
    await db.insert('recipes', {'menu_id': m4, 'inventory_id': patiId, 'required_qty': 2});
    await db.insert('recipes', {'menu_id': m4, 'inventory_id': chanaId, 'required_qty': 1});
    await db.insert('recipes', {'menu_id': m4, 'inventory_id': chatniId, 'required_qty': 1});

    // Cold Drink = 1 Bottle
    await db.insert('recipes', {'menu_id': m5, 'inventory_id': cokeId, 'required_qty': 1});
  }

  Future<List<MenuItem>> getMenuItems() async {
    final db = await instance.database;
    final result = await db.query('menu');
    return result.map((json) => MenuItem.fromMap(json)).toList();
  }

  Future<List<InventoryItem>> getInventory() async {
    final db = await instance.database;
    final result = await db.query('inventory');
    return result.map((json) => InventoryItem.fromMap(json)).toList();
  }

  // Deduct Inventory automatically using BOM logic
  Future<void> processSale(List<CartItem> cartItems, String paymentMethod, String tokenNo) async {
    final db = await instance.database;

    await db.transaction((txn) async {
      double grandTotal = 0;

      for (var cart in cartItems) {
        grandTotal += cart.total;

        // Query recipe rules for this item
        final recipes = await txn.query(
          'recipes',
          where: 'menu_id = ?',
          whereArgs: [cart.item.id],
        );

        for (var rule in recipes) {
          int invId = rule['inventory_id'] as int;
          double reqQty = (rule['required_qty'] as num).toDouble();
          double totalDeduction = reqQty * cart.quantity;

          // Deduct from Stock
          await txn.rawUpdate(
            'UPDATE inventory SET stock_qty = stock_qty - ? WHERE id = ?',
            [totalDeduction, invId],
          );
        }
      }

      // Record Sales Transaction
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
      title: 'Samosa Shop POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFD84315), // Warm Samosa Orange/Brown
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        title: Text(
          widget.isUrdu ? 'زم زم سموسہ پوائنٹ POS' : 'Zam Zam Samosa Point POS',
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 22),
        ),
        actions: [
          // Language Switcher
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
          // 1. POS Terminal
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

          // 2. Table & Tokens Manager
          TablesView(
            isUrdu: widget.isUrdu,
            tokens: activeTokens,
            onSelectToken: (token) {
              setState(() {
                cart = List.from(token.items);
                activeTable = token.tableName;
                currentTokenNo = token.tokenNo;
                _selectedIndex = 0; // Switch to POS terminal
              });
            },
          ),

          // 3. Inventory & Recipes
          InventoryView(isUrdu: widget.isUrdu),

          // 4. Reports
          ReportsView(isUrdu: widget.isUrdu),
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
            label: widget.isUrdu ? 'ٹیبلز (Tables)' : 'Tables & Tokens',
          ),
          NavigationDestination(
            icon: const Icon(Icons.inventory, size: 28),
            label: widget.isUrdu ? 'سٹاک (Stock)' : 'Inventory',
          ),
          NavigationDestination(
            icon: const Icon(Icons.bar_chart, size: 28),
            label: widget.isUrdu ? 'رپورٹس (Reports)' : 'Reports',
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

  @override
  void initState() {
    super.initState();
    _menuItemsFuture = DatabaseHelper.instance.getMenuItems();
  }

  double get cartTotal => widget.cart.fold(0, (sum, item) => sum + item.total);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // LEFT: Menu Grid (2/3 Width)
        Expanded(
          flex: 3,
          child: FutureBuilder<List<MenuItem>>(
            future: _menuItemsFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }

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
                    color: Colors.orange.shade50,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => widget.onAddToCart(item),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(item.icon, style: const TextStyle(fontSize: 48)),
                          const SizedBox(height: 8),
                          Text(
                            widget.isUrdu ? item.nameUr : item.nameEn,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            'Rs. ${item.price.toStringAsFixed(0)}',
                            style: TextStyle(fontSize: 18, color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
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

        // RIGHT: Cart & Billing (1/3 Width)
        Expanded(
          flex: 2,
          child: Card(
            margin: const EdgeInsets.all(8),
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  // Header Banner
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

                  // Cart Items List
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
                                subtitle: Text('Rs. ${cartItem.item.price} x ${cartItem.quantity}'),
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

                  // Total & Checkout
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
                          'Rs. ${cartTotal.toStringAsFixed(0)}',
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.green),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Action Buttons
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
                          onPressed: widget.cart.isEmpty
                              ? null
                              : () => _showCheckoutDialog(context),
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
              title: Text(widget.isUrdu ? 'آن لائن / UPI' : 'UPI / Online QR'),
              onTap: () {
                Navigator.pop(ctx);
                _completePayment('UPI');
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

    // Show Receipt Modal
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => ReceiptPreviewModal(
        cartItems: List.from(widget.cart),
        total: cartTotal,
        paymentMethod: method,
        tokenNo: widget.tokenNo,
        isUrdu: widget.isUrdu,
      ),
    );

    widget.onCheckoutSuccess();
  }
}

/* ============================================================================
 * VIEW 2: TABLES & TOKENS VIEW
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
                    // Create new customer token under this table
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
 * VIEW 3: INVENTORY & BOM CONSUMPTION VIEW
 * ========================================================================= */
class InventoryView extends StatelessWidget {
  final bool isUrdu;

  const InventoryView({super.key, required this.isUrdu});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<InventoryItem>>(
      future: DatabaseHelper.instance.getInventory(),
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
                trailing: Text(
                  '${item.stockQty.toStringAsFixed(1)} ${item.unit}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: isLow ? Colors.red : Colors.black,
                  ),
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
 * VIEW 4: REPORTS VIEW
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
 * THERMAL RECEIPT MODAL WITH UPI QR CODE & BARCODE
 * ========================================================================= */
class ReceiptPreviewModal extends StatelessWidget {
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
  Widget build(BuildContext context) {
    String billNo = 'INV-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';

    return Container(
      padding: const EdgeInsets.all(24),
      height: MediaQuery.of(context).size.height * 0.85,
      child: Column(
        children: [
          const Text('Thermal Receipt Preview (58mm/80mm)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Divider(),

          // Receipt Simulation Container
          Expanded(
            child: SingleChildScrollView(
              child: Container(
                width: 320, // 80mm thermal printer style width
                padding: const EdgeInsets.all(16),
                color: Colors.white,
                child: Column(
                  children: [
                    const Text('ZAM ZAM SAMOSA SHOP', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const Text('Main Bazaar Layyah'),
                    const Text('Ph: +92 300 1234567'),
                    const Divider(thickness: 2),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Token: $tokenNo', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text('Bill: $billNo'),
                      ],
                    ),
                    const Divider(),

                    // Items List
                    ...cartItems.map((c) => Padding(
                          padding: const EdgeInsets.vertical: 4.0,
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
                        Text('Rs. ${total.toStringAsFixed(0)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      ],
                    ),
                    Text('Payment: $paymentMethod', style: const TextStyle(fontStyle: FontStyle.italic)),
                    const SizedBox(height: 12),

                    // UPI QR Code Generator
                    QrImageView(
                      data: 'upi://pay?pa=zamzamsamosa@upi&pn=ZamZamSamosa&am=$total',
                      version: QrVersions.auto,
                      size: 120.0,
                    ),
                    const Text('Scan to Pay via UPI', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 12),

                    // Barcode Generator
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