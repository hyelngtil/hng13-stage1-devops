from flask import Flask
from datetime import datetime

app = Flask(__name__)

@app.route('/')
def home():
    return f'''
    <html>
        <body style="font-family: Arial; text-align: center; padding: 50px;">
            <h1>🚀 Deployment Successful!</h1>
            <p>Your automated deployment script is working!</p>
            <p>Server Time: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>
        </body>
    </html>
    '''

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)