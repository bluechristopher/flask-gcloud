import os
import sqlite3
from datetime import datetime
import pytz
from flask import Flask, render_template, request, redirect, url_for, flash
from google.cloud import storage

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "super-secret-key-for-flask")

# Paths and Configs
DB_PATH = "/tmp/greetings.db"
BUCKET_NAME = os.environ.get("BUCKET_NAME")

# Helper for Singapore Time
def get_singapore_time():
    sg_tz = pytz.timezone('Asia/Singapore')
    return datetime.now(sg_tz).strftime('%Y-%m-%d %H:%M:%S')

def get_storage_client():
    try:
        # This will use Application Default Credentials (ADC) in Google Cloud
        return storage.Client()
    except Exception as e:
        app.logger.warning(f"Failed to create Google Cloud Storage client: {e}")
        return None

def download_db():
    if not BUCKET_NAME:
        return
    client = get_storage_client()
    if not client:
        return
    try:
        bucket = client.bucket(BUCKET_NAME)
        blob = bucket.blob("greetings.db")
        if blob.exists():
            blob.download_to_filename(DB_PATH)
            app.logger.info("Successfully downloaded greetings.db from GCS bucket.")
        else:
            app.logger.info("greetings.db not found in bucket. Initializing a new database.")
            init_local_db()
            upload_db()
    except Exception as e:
        app.logger.error(f"Error downloading db from GCS: {e}")
        # Ensure we have at least a local database if download failed
        if not os.path.exists(DB_PATH):
            init_local_db()

def upload_db():
    if not BUCKET_NAME:
        return
    client = get_storage_client()
    if not client:
        return
    try:
        bucket = client.bucket(BUCKET_NAME)
        blob = bucket.blob("greetings.db")
        blob.upload_from_filename(DB_PATH)
        app.logger.info("Successfully uploaded greetings.db to GCS bucket.")
    except Exception as e:
        app.logger.error(f"Error uploading db to GCS: {e}")

def init_local_db():
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS Greeting (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                message TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
        """)
        conn.commit()
        conn.close()
    except Exception as e:
        app.logger.error(f"Error initializing local database: {e}")

# Initialise DB on startup
if BUCKET_NAME:
    download_db()
else:
    init_local_db()

@app.route('/')
def index():
    # Retrieve latest DB from GCS
    if BUCKET_NAME:
        download_db()
    else:
        init_local_db()
        
    greetings = []
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        cursor.execute("SELECT id, name, message, created_at FROM Greeting ORDER BY id DESC")
        rows = cursor.fetchall()
        
        for r in rows:
            # Parse and format the date string beautifully
            formatted_date = r['created_at']
            if formatted_date:
                try:
                    # Assumes standard YYYY-MM-DD HH:MM:SS format from SQLite
                    dt_obj = datetime.strptime(formatted_date, '%Y-%m-%d %H:%M:%S')
                    formatted_date = dt_obj.strftime('%d %B %Y, %I:%M %p')
                    
                    # Strip leading zero from the day if present (e.g., '09 July' -> '9 July')
                    if formatted_date.startswith('0'):
                        formatted_date = formatted_date[1:]
                except ValueError:
                    # Fallback in case the database format varies slightly
                    pass

            greetings.append({
                'name': r['name'],
                'message': r['message'],
                'created_at': formatted_date
            })
        conn.close()
    except Exception as e:
        app.logger.error(f"Failed to fetch greetings: {e}")
        flash("Error loading greetings from database.", "error")
        
    return render_template('index.html', greetings=greetings)

@app.route('/add', methods=['POST'])
def add_greeting():
    name = request.form.get('name', '').strip()
    message = request.form.get('message', '').strip()
    
    if not name or not message:
        flash("Name and message are required.", "error")
        return redirect(url_for('index'))
        
    if len(name) > 100 or len(message) > 1000:
        flash("Input length exceeds safety limit.", "error")
        return redirect(url_for('index'))
        
    # Retrieve latest DB from GCS
    if BUCKET_NAME:
        download_db()
    else:
        init_local_db()
        
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        
        # Check database entry limits
        cursor.execute("SELECT COUNT(*) FROM Greeting")
        count = cursor.fetchone()[0]
        
        if count >= 200:
            flash("Greeting limit reached. Cannot add more greetings.", "error")
            conn.close()
            return redirect(url_for('index'))
            
        # Insert greeting record
        sg_time = get_singapore_time()
        cursor.execute("INSERT INTO Greeting (name, message, created_at) VALUES (?, ?, ?)", (name, message, sg_time))
        conn.commit()
        conn.close()
        
        # Upload updated DB back to bucket
        if BUCKET_NAME:
            upload_db()
            
        flash("Greeting added successfully!", "success")
    except Exception as e:
        app.logger.error(f"Error adding greeting: {e}")
        flash("Failed to add greeting to database.", "error")
        
    return redirect(url_for('index'))

@app.route('/delete/<int:greeting_id>', methods=['POST'])
def delete_greeting(greeting_id):
    # Retrieve latest DB from GCS
    if BUCKET_NAME:
        download_db()
    else:
        init_local_db()
        
    try:
        conn = sqlite3.connect(DB_PATH)
        cursor = conn.cursor()
        cursor.execute("DELETE FROM Greeting WHERE id = ?", (greeting_id,))
        conn.commit()
        conn.close()
        
        # Upload updated DB back to bucket
        if BUCKET_NAME:
            upload_db()
            
        flash("Greeting deleted successfully.", "success")
    except Exception as e:
        app.logger.error(f"Error deleting greeting: {e}")
        flash("Failed to delete greeting from database.", "error")
        
    return redirect(url_for('index'))

if __name__ == '__main__':
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=True)
