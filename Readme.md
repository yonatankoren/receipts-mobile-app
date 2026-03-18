# 📄 Receipts- Easy Expenses Managment

**receipt management with full user data ownership- easy, fast, robust**

An Andorid mobile app that scans receipts, extracts structured expense data with AI, organizes everything automatically, and stores all files directly in the user’s own Google Drive and Google Sheets.

Designed for freelancers, small business owners, and anyone who wants a simple and reliable way to keep track with his expenses.

---

## 🚀 Why This Project Exists

The idea for this app came to me when I saw my father spending an entire afternoon organizing a full month’s worth of receipts in order to send them to his accountant.

I discovered that **managing receipts is surprisingly painful**, and decided to make his life easier.

**What he used to do:**
- collected receipts throughout the month
- manually entered them into spreadsheets
- sended messy folders to his accountant

**What he is doing now:**
- scans receipts immediately
- sends his accountant an organized zip file with a monthly summery with one in app tap. 

---

## ✨ Key Product Ideas

This app was built around three design principles:

### 🔐 Familiar and Robust Data Storege and Organization

All data belongs to the user:
- **receipt images** → Google Drive
- **expense data** → Google Sheets

Those tools by Google are well- established and are already used by many freelancers.  Using them for core storage and organization gives the user **a familiar and trusted experiance**.   

---

### ⚡ Fast and Human Friendly

The workdays of a freelancer are full of action. **Managing receipts can't become a tidious task**. 

**The app is desigened to be fast and easy to use:**
- **Scanning:** capture → automatic data extraction → review and fix -> save receipt.
- **Exporting:** send receipts of a full month through your favorite platform in a few taps.

---

### 🤖 AI-Assisted Receipt Extraction

**Data extraction has to be precise**. To achieve that receipts are automatically parsed using:
- Google Vision OCR
- OpenAI LLM

Also, users can review and edit the results before saving.

---

## 📊 Features

### 📷 Receipt Capture

Users can add receipts using multiple methods:
- Camera scanning
- Image upload from gallery
- PDF or document upload
- Android Share (send receipt directly from other apps)

---

### 🧾 Review & Correction Screen

Before saving a receipt, users can review extracted data:
- merchant
- date
- amount
- currency
- category

If the receipt currency is not ILS, the screen shows a live conversion preview.

Example:

≈ ₪90.43

This allows users to immediately understand the value in local currency.

---

### 📊 Expense Statistics

The app includes a **built-in statistics dashboard** showing:
- total expenses
- spending by category
- monthly breakdown

All statistics are normalized to ILS for consistent comparison.

---

### 📤 Accountant Export

Users can export receipts for selected months.

The app **automatically** generates a ZIP file containing:

```
expenses_03_04_2026_Name.zip

March/
   Food/
   Transport/

April/
   Equipment/

summary.csv
```

The file can then be shared directly via:
- Gmail
- WhatsApp
- Android Share

Also, **accountant's adress can be predefined** in settings to make even faster exporting.

---

### 🔁 Robust Sync System

**Receipt processing is designed to survive interruptions.**

The app includes:
- SQLite job queue
- automatic retry on app restart
- idempotent Drive & Sheets operations
- background sync recovery

Even if the app closes mid-process, the receipt will continue syncing later.

---

### 💱 Multi-Currency Support

**Receipts may arrive in different currencies.**

The app stores:
- original amount
- original currency
- converted ILS amount

The converted value is used for:
- statistics
- totals
- accountant exports

Exchange rates are fetched dynamically and cached.

---

## 🏗 Architecture

```
Mobile App (Flutter)
        │
        ▼
Backend Service
        │
        ├── Google Vision OCR
        └── OpenAI LLM
        │
        ▼
Structured JSON
        │
        ├── Upload file → Google Drive
        └── Write row → Google Sheets
```

**Key idea:**

The backend processes receipts but does not store user data.

All persistent data lives in the user’s own Google account.

---

## 🛠 Tech Stack

**Mobile**
- Flutter

**AI Pipeline**
- Google Vision OCR
- OpenAI LLM
- Hosted on Google Cloud Run

**Cloud Storage**
- Google Drive API
- Google Sheets API

**Authentication**
- Google OAuth

**Local Data**
- SQLite job queue

---

## 📱 App Screenshots

<p align="center">
  <img src="screenshots/camera.jpeg" width="260"/>
  <img src="screenshots/review.jpeg" width="260"/>
</p>

<p align="center">
  <img src="screenshots/statistics.jpeg" width="260"/>
</p>

### 📑 Google Sheets Ledger

<p align="center">
  <img src="screenshots/sheets-expenses.png" width="700"/>
  <img src="screenshots/sheets-totals.png" width="700"/>
</p>