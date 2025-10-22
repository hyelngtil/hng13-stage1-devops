from flask import Flask
from datetime import datetime

app = Flask(__name__)

@app.route('/')
def home():
    return f'''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Stage1 HNG13 Deployment Successful!</title>
      <style>
        body {{
          font-family: Arial, sans-serif;
          display: flex;
          justify-content: center;
          align-items: center;
          height: 100vh;
          margin: 0;
          background: linear-gradient(135deg, #3f8bcd 0%, #2a629a 100%);
          color: white;
        }}
        .container {{
          text-align: center;
          padding: 2rem;
          background: rgba(255, 255, 255, 0.1);
          border-radius: 10px;
          backdrop-filter: blur(10px);
        }}
        h1 {{ margin-bottom: 1rem; }}
        .timestamp {{ font-size: 0.9em; opacity: 0.8; }}
      </style>
    </head>
    <body>
      <div class="container">
        <h1>🚀Stage1 HNG13 Deployment Successful!</h1>
        <p>Your automated deployment script is working!</p>
        <p class="timestamp">Server Time: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>
      </div>
    </body>
    </html>
    '''

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)