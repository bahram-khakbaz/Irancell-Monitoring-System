
# 📘 FULL SYSTEM DOCUMENTATION (Irancell Monitoring System)

```markdown id="u8d9qk"
# 📡 Irancell Internet Usage Monitoring System

A fully containerized production-grade monitoring system that automatically logs into Irancell Business Portal, extracts remaining internet quota, stores historical data in PostgreSQL, and visualizes metrics in Grafana.

---

# 🚀 1. System Overview

This system is designed to:

- Login automatically to Irancell Business Panel
- Navigate through multi-level organizational UI
- Extract remaining internet usage (GB / TB)
- Store time-series data in PostgreSQL
- Visualize trends in Grafana
- Send email alerts when usage is low
- Run as a scheduled daily job (cron-based)

---

# 🧱 2. Architecture

```

[Irancell Web Portal]
↓
[Playwright Scraper (Python)]
↓
[PostgreSQL Database]
↓
[Grafana Dashboard]
↓
[Email Alerts (SMTP)]

````

---

# 🖥️ 3. Server Requirements

## Minimum Requirements
- Ubuntu 24.04+
- 2 CPU
- 2GB RAM (minimum)
- Docker + Docker Compose

## Install Dependencies

```bash id="9k3d0x"
sudo apt update
sudo apt install -y docker.io docker-compose-plugin git curl
sudo systemctl enable docker
sudo systemctl start docker
```

---

# 📁 4. Project Directory Structure

Create base directory:

```bash id="w1p9xk"
sudo mkdir -p /opt/irancell-monitor
sudo chown -R $USER:$USER /opt/irancell-monitor
cd /opt/irancell-monitor
```

Final structure:

```
irancell-monitor/
├── docker-compose.yml
├── .env
├── scraper/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── scraper.py
├── data/
└── grafana-storage/
```

---

# 🐳 5. Docker Compose Setup

Create:

```bash id="z8c2qp"
nano docker-compose.yml
```

```yaml id="x7v2ab"
version: '3.8'

services:
  db:
    image: postgres:15-alpine
    container_name: irancell_postgres
    restart: always
    environment:
      POSTGRES_USER: irancell_user
      POSTGRES_PASSWORD: SecretPassword123
      POSTGRES_DB: irancell_db
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

  scraper:
    build: ./scraper
    container_name: irancell_scraper
    restart: "no"
    depends_on:
      - db
    env_file:
      - .env
    environment:
      DB_HOST: db
      DB_USER: irancell_user
      DB_PASSWORD: SecretPassword123
      DB_NAME: irancell_db
      DB_PORT: 5432

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: always
    ports:
      - "80:3000"
    depends_on:
      - db
    volumes:
      - grafana-storage:/var/lib/grafana

volumes:
  postgres_data:
  grafana-storage:
```

---

# 🔐 6. Environment Configuration

Create `.env`:
```bash id="k2m8vn"
nano .env
---
```env id="p0q7ds"
USERNAME=your_irancell_number
PASSWORD=your_password

ALERT_EMAIL=email1@example.com,email2@example.com

SMTP_USER=smtp_user
SMTP_PASS=smtp_password
```

---

# 🧠 7. Scraper Service

## Dockerfile

```bash id="r1v8zx"
nano scraper/Dockerfile
```

```dockerfile id="o8d2pq"
FROM python:3.11-slim

WORKDIR /app

# جلوگیری از دانلود Chromium توسط Playwright
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# نصب Chromium سیستم (snap path را استفاده می‌کنیم)
RUN apt-get update && apt-get install -y \
    chromium \
    fonts-liberation \
    libnss3 \
    libatk1.0-0 \
    libx11-xcb1 \
    libxcomposite1 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libpangocairo-1.0-0 \
    libgtk-3-0 \
    && rm -rf /var/lib/apt/lists/*

# نصب پایتون dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# کپی پروژه
COPY . .

CMD ["python3", "scraper.py"]

```

---

## Requirements

```bash id="q9x1kl"
nano scraper/requirements.txt
```

```txt id="u3m8pv"
playwright
requests
playwright==1.42.0
python-dotenv==1.0.1
psycopg2-binary

```

---

## Scraper Logic (Core Flow)

```Python id="sr5tsrZ"
from playwright.sync_api import sync_playwright
import psycopg2
import os
import re
import smtplib
from email.mime.text import MIMEText
from datetime import datetime, timedelta
from dotenv import load_dotenv

# لود کردن انوایرومنت (هم لوکال هم داکر)
load_dotenv("/opt/irancell-monitor/.env")

USERNAME = os.getenv("USERNAME")
PASSWORD = os.getenv("PASSWORD")
ALERT_EMAIL = os.getenv("ALERT_EMAIL")

SMTP_SERVER = "smtp.digikala.com"
SMTP_PORT = 587
SMTP_USER = os.getenv("SMTP_USER")
SMTP_PASS = os.getenv("SMTP_PASS")

# --- تنظیمات اتصال به PostgreSQL ---
DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = os.getenv("DB_PORT", "5432")
DB_NAME = os.getenv("DB_NAME", "irancell_db")
DB_USER = os.getenv("DB_USER", "irancell_user")
DB_PASS = os.getenv("DB_PASSWORD", "SecretPassword123")


# ---------- POSTGRESQL DB ----------
def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )


def init_db():
    conn = get_db_connection()
    c = conn.cursor()

    c.execute("""
    CREATE TABLE IF NOT EXISTS usage_logs (
        id SERIAL PRIMARY KEY,
        timestamp TIMESTAMP,
        remaining_gb NUMERIC(10, 2)
    )
    """)

    c.execute("""
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY,
        value TEXT
    )
    """)

    conn.commit()
    c.close()
    conn.close()


def get_meta(key):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("SELECT value FROM meta WHERE key=%s", (key,))
    row = c.fetchone()
    c.close()
    conn.close()
    return row[0] if row else None


def set_meta(key, value):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("""
    INSERT INTO meta (key, value)
    VALUES (%s, %s)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
    """, (key, value))
    conn.commit()
    c.close()
    conn.close()


def save_data(gb):
    conn = get_db_connection()
    c = conn.cursor()
    c.execute(
        "INSERT INTO usage_logs (timestamp, remaining_gb) VALUES (%s, %s)",
        (datetime.now(), gb)
    )
    conn.commit()
    c.close()
    conn.close()


def cleanup():
    conn = get_db_connection()
    c = conn.cursor()
    c.execute("""
        DELETE FROM usage_logs
        WHERE timestamp < NOW() - INTERVAL '10 days'
    """)
    conn.commit()
    c.close()
    conn.close()


# ---------- EMAIL ----------
def send_email(msg):
    message = MIMEText(msg)
    message['Subject'] = "Irancell Alert - Low Volume"
    message['From'] = SMTP_USER
    message['To'] = ALERT_EMAIL or ""

    try:
        to_addresses = [email.strip() for email in (ALERT_EMAIL or "").split(",") if email.strip()]

        with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=15) as server:
            server.ehlo()
            server.starttls()
            server.ehlo()
            server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(SMTP_USER, to_addresses, message.as_string())
        print("[INFO] Alert email sent successfully to all recipients.")
    except Exception as e:
        print(f"[ERROR] Failed to send email: {e}")


# ---------- SCRAPER ----------
def login_and_get_data():
    with sync_playwright() as p:
        chrome_path = "/usr/bin/chromium" if os.path.exists("/usr/bin/chromium") else "/snap/bin/chromium"

        browser = p.chromium.launch(
            headless=True,
            executable_path=chrome_path,
            args=[
                "--no-sandbox",
                "--disable-dev-shm-usage",
                "--disable-gpu"
            ]
        )

        page = browser.new_page()

        # 1. ورود به صفحه لاگین
        print("[INFO] Navigating to login page...")
        page.goto("https://mybusiness.irancell.ir/login", timeout=60000)

        page.wait_for_selector('input[type="text"]', timeout=30000)
        page.fill('input[type="text"]', USERNAME or "")
        page.get_by_role("button", name="ادامه").click()

        # 2. انتخاب متد رمز عبور ثابت
        page.wait_for_selector("text=رمز عبور ثابت", timeout=30000)
        page.get_by_text("رمز عبور ثابت", exact=False).click()

        # 3. وارد کردن پسورد و تایید
        page.wait_for_selector('input[type="password"]', timeout=30000)
        page.fill('input[type="password"]', PASSWORD or "")
        page.get_by_role("button", name="تایید").click()

        # 4. انتظار برای ورود به داشبورد
        try:
            page.wait_for_url("**/dashboard**", timeout=40000)
        except:
            pass

        page.wait_for_load_state("networkidle", timeout=40000)
        print("[INFO] After login URL:", page.url)

        if "login" in page.url:
            print("[ERROR] Login failed")
            try:
                page.screenshot(path="login_error.png")
                print("[INFO] Screenshot saved inside container as login_error.png")
            except Exception as e:
                print(f"[WARN] Failed to take screenshot: {e}")
            browser.close()
            return None

        # 5. کلیک روی خدمات سازمانی
        print("[INFO] Clicking on 'خدمات سازمانی'...")
        try:
            page.wait_for_selector("text=خدمات سازمانی", timeout=30000)
            page.get_by_text("خدمات سازمانی").first.click()
        except Exception as e:
            print(f"[WARN] Selector failed, trying backup locator for services: {e}")
            page.locator("text=/خدمات.*سازمانی/").first.click()

        page.wait_for_timeout(3000)  # زمان برای رندر شدن زیرمنوها

        # 6. کلیک روی حساب های چند کاربره
        print("[INFO] Clicking on 'حساب های چند کاربره'...")
        try:
            page.wait_for_selector("text=حساب های چند کاربره", timeout=30000)
            page.get_by_text("حساب های چند کاربره").first.click()
        except Exception as e:
            print(f"[WARN] Selector failed, trying backup locator for multi-user: {e}")
            page.locator("text=/حساب.*چند.*کاربره/").first.click()

        # انتظار برای لود شدن کامل جدول رکوردها
        print("[INFO] Waiting for multi-user table to fully load...")
        page.wait_for_load_state("networkidle", timeout=40000)
        page.wait_for_timeout(10000)

        # 7. کلیک روی منوی سه نقطه سمت راست ردیف اول جدول
        print("[INFO] Clicking on the three-dots menu...")
        try:
            page.wait_for_selector("tbody button", timeout=20000)
            page.locator("tbody button").first.click()
        except Exception as e:
            print(f"[WARN] Standard button selector failed, trying svg container: {e}")
            page.locator("button:has(svg)").first.click()

        page.wait_for_timeout(3000)

        # 8. کلیک روی مدیریت زیرشاخه ها در منوی باز شده
        print("[INFO] Clicking on 'مدیریت زیرشاخه ها'...")
        clicked = False
        try:
            menu_item = page.locator("text=/مدیریت.*زیرشاخه/").first
            if menu_item.is_visible():
                menu_item.click()
                clicked = True
        except:
            pass

        if not clicked:
            # روش جایگزین با تزریق جاوا اسکریپت در صورت لود پیچیده ساب‌منو
            clicked = page.evaluate("""
            () => {
                const elements = Array.from(document.querySelectorAll('*'));
                for (const el of elements) {
                    if (el.innerText) {
                        const text = el.innerText;
                        if (text.includes('زیرشاخه') || text.includes('مدیریت')) {
                            const rect = el.getBoundingClientRect();
                            if (rect.width > 0 && rect.height > 0) {
                                el.click();
                                return true;
                            }
                        }
                    }
                }
                return false;
            }
            """)

        if not clicked:
            print("[ERROR] 'مدیریت زیرشاخه ها' menu item not found or not clickable")
            browser.close()
            return None

        # 9. انتظار برای لود شدن پاپ‌آپ/صفحه مودال حاوی حجم باقی‌مانده
        print("[INFO] Waiting for remaining usage data to render...")
        page.wait_for_timeout(12000)

        # 10. استخراج مقدار حجم باقی‌مانده (پشتیبانی جامع از ترابایت و گیگابایت فارسی/انگلیسی)
        html = page.content()
        browser.close()

        # تابع کمکی برای تبدیل اعداد فارسی/عربی به انگلیسی
        def clean_number(num_str):
            persian_digits = '۰۱۲۳۴۵۶۷۸۹'
            arabic_digits = '٠١٢٣٤٥٦٧٨٩'
            for i, (p, a) in enumerate(zip(persian_digits, arabic_digits)):
                num_str = num_str.replace(p, str(i)).replace(a, str(i))
            return float(num_str)

        # الگوهای جستجو برای ترابایت و گیگابایت (فارسی و انگلیسی)
        match_tb = re.search(r'([\d۰-۹.]+)\s*(?:ترابایت|TB|tb)', html)
        match_gb = re.search(r'([\d۰-۹.]+)\s*(?:گیگابایت|GB|gb)', html)

        if match_tb:
            raw_val = match_tb.group(1)
            val_en = clean_number(raw_val)
            print(f"[INFO] Detected volume in Terabytes: {val_en} TB")
            return val_en * 1024  # تبدیل ترابایت به گیگابایت برای پایداری دیتا در گرافانا
        elif match_gb:
            raw_val = match_gb.group(1)
            val_en = clean_number(raw_val)
            print(f"[INFO] Detected volume in Gigabytes: {val_en} GB")
            return val_en

        print("[ERROR] Remaining usage volume string (GB/TB) not found in HTML text")
        try:
            with open("failed_page_source.html", "w", encoding="utf-8") as f:
                f.write(html)
            print("[INFO] Saved page source to failed_page_source.html for debugging")
        except Exception as dbg_err:
            print(f"[WARN] Could not save failed page source: {dbg_err}")

        return None


# ---------- MAIN ----------
if __name__ == "__main__":
    init_db()

    now = datetime.now()
    timestamp_str = now.strftime('%Y-%m-%d %H:%M:%S')

    print(f"[{timestamp_str}] [INFO] Starting scraper execution check...")
    last_login = get_meta("last_login")
    need_login = True

    if last_login:
        try:
            last_time = datetime.fromisoformat(last_login)
            if now - last_time < timedelta(days=1):
                need_login = False
        except Exception as e:
            print(f"[{timestamp_str}] [WARN] Failed to parse last_login timestamp: {e}. Re-logging in...")
            need_login = True

    if need_login:
        print(f"[{timestamp_str}] [INFO] Running login (1-day cycle)")
        gb = login_and_get_data()

        if gb is not None:
            print(f"[{timestamp_str}] [OK] Remaining GB fetched: {gb}")
            save_data(gb)
            cleanup()
            set_meta("last_login", now.isoformat())

            if gb < 1500.0:
                send_email(f"LOW INTERNET ALERT: Only {gb} GB remaining on Mother SIM Card!")
        else:
            print(f"[{timestamp_str}] [ERROR] Failed to fetch data from panel")
    else:
        print(f"[{timestamp_str}] [INFO] Skipped (within 1-day window). Last successful login was at: {last_login}")


The scraper performs:

### 1. Login Flow
- Opens Irancell portal
- Enters username
- Selects password login method
- Authenticates user

### 2. Navigation Flow
- خدمات سازمانی
- حساب‌های چند کاربره
- مدیریت زیرشاخه‌ها

### 3. Data Extraction
- Extracts remaining internet usage
- Supports GB / TB parsing
- Converts TB → GB for consistency

### 4. Storage
- Inserts data into PostgreSQL

---

# 🗄️ 8. Database Schema

Automatically created by scraper:

## usage_logs

| Column | Type |
|--------|------|
| id | SERIAL |
| timestamp | TIMESTAMP |
| remaining_gb | NUMERIC |

## meta

| key | value |
|-----|-------|
| key-value storage |

---

# 🚀 9. Run System

```bash id="c3n9qp"
docker compose up -d --build
```

---

# ⏰ 10. Scheduling (CRITICAL)

Since scraper is batch-based:

## Recommended Cron Job

```bash id="v7m2ds"
crontab -e
```

```bash id="t1p9xa"
0 0 * * * cd /opt/irancell-monitor && docker compose run --rm scraper
```

---

# 📊 11. Grafana Setup

Open:

```
http://SERVER_IP
```

Login:

```
admin / admin
```

---

## Add Data Source

- Type: PostgreSQL
- Host: db:5432
- Database: irancell_db
- User: Your User name set
- Password: Your password set 

---

## Sample Query

```sql id="z0k3pm"
SELECT
  timestamp,
  remaining_gb
FROM usage_logs
ORDER BY timestamp ASC;
```

---

# 📈 12. Dashboard

Create:

- Time Series Panel
- Metric: remaining_gb
- X-axis: timestamp

---

# 📬 13. Alerts System

If usage drops below threshold:

- Email sent via SMTP
- Supports multiple recipients

---

# ⚠️ 14. Known Issues

### Login Failure
- UI changes in portal
- selector mismatch
- session expiry
- anti-bot detection

### No Data in Grafana
- scraper did not execute
- DB connection issue
- cron not running

### Container exits immediately
- expected behavior (batch job model)

---

# 🧪 15. Debugging

```bash id="x2v9pq"
docker logs irancell_scraper
```

Check DB:

```bash id="q8m1zd"
docker exec -it irancell_postgres psql -U irancell_user -d irancell_db
```

---

# 🔐 16. Security Notes

- Never commit `.env` file
- Rotate SMTP credentials periodically
- Restrict DB port in production
- Use internal network for Grafana if possible

---

# 📁 17. Backup Strategy

Recommended:

```bash id="k7n3qa"
docker exec irancell_postgres pg_dump -U irancell_user irancell_db > backup.sql
```

---

# 👨‍💻 18. Author

Enterprise-grade telecom usage monitoring system.
---
👉 “:contentReference[oaicite:6]{index=6}”
````
