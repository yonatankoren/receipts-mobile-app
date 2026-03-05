/// Expense model — represents a manual expense entry without a receipt.
/// Stored in the `expenses` table in SQLite.
/// Once a receipt is attached and confirmed, the expense is deleted.

class Expense {
  final String id; // UUID
  final String name; // תיאור ההוצאה
  final String date; // ISO date YYYY-MM-DD
  final double amount; // סכום מדווח
  final String paidTo; // שולם ל
  final DateTime createdAt;

  Expense({
    required this.id,
    required this.name,
    required this.date,
    required this.amount,
    required this.paidTo,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'date': date,
      'amount': amount,
      'paid_to': paidTo,
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }

  factory Expense.fromMap(Map<String, dynamic> map) {
    return Expense(
      id: map['id'] as String,
      name: map['name'] as String,
      date: map['date'] as String,
      amount: (map['amount'] as num).toDouble(),
      paidTo: map['paid_to'] as String,
      createdAt: map['created_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int)
          : DateTime.now(),
    );
  }
}

