#!/usr/bin/env python3
import json
import os
import requests
from datetime import datetime
from pathlib import Path

def main():
    # Конфигурация
    repo_owner = "sadadscasd"
    repo_name = "Dead_Rails_script"
    data_file = "access_data.json"
    local_data_file = "data/access_data_local.json"
    github_token = os.getenv('GITHUB_TOKEN')
    
    if not github_token:
        print("❌ GITHUB_TOKEN not found in secrets")
        return

    # Создаем папку data если её нет
    Path("data").mkdir(exist_ok=True)
    
    # Проверяем наличие локального файла
    if not Path(local_data_file).exists():
        print("📁 Local data file not found, creating empty one")
        with open(local_data_file, 'w') as f:
            json.dump([], f, indent=2)
        return

    # Читаем локальные данные
    try:
        with open(local_data_file, 'r') as f:
            local_data = json.load(f)
    except json.JSONDecodeError:
        print("❌ Error reading local data file")
        return

    if not local_data:
        print("📊 No local data to update")
        return

    # Получаем текущие данные с GitHub
    headers = {
        'Authorization': f'token {github_token}',
        'Accept': 'application/vnd.github.v3+json'
    }
    
    url = f'https://api.github.com/repos/{repo_owner}/{repo_name}/contents/{data_file}'
    
    try:
        response = requests.get(url, headers=headers)
        if response.status_code == 200:
            current_data = response.json()
            sha = current_data['sha']
            
            # Декодируем содержимое (base64)
            import base64
            content = base64.b64decode(current_data['content']).decode('utf-8')
            github_data = json.loads(content)
        else:
            # Файл не существует, создаем новый
            github_data = []
            sha = None
            print("📄 Creating new data file on GitHub")
            
    except requests.RequestException as e:
        print(f"❌ Error fetching GitHub data: {e}")
        return

    # Обновляем данные
    updated = False
    for local_user in local_data:
        user_exists = False
        for i, github_user in enumerate(github_data):
            if github_user.get('userId') == local_user.get('userId'):
                # Обновляем существующего пользователя
                github_data[i] = local_user
                user_exists = True
                updated = True
                print(f"🔄 Updated user: {local_user.get('username')}")
                break
        
        if not user_exists:
            # Добавляем нового пользователя
            github_data.append(local_user)
            updated = True
            print(f"➕ Added new user: {local_user.get('username')}")

    if not updated:
        print("✅ No updates needed")
        return

    # Сортируем по userId для удобства
    github_data.sort(key=lambda x: x.get('userId', 0))

    # Подготавливаем данные для отправки
    content = json.dumps(github_data, indent=2, ensure_ascii=False)
    content_base64 = base64.b64encode(content.encode('utf-8')).decode('utf-8')

    # Отправляем обновление
    update_data = {
        'message': '🤖 Auto-update access data',
        'content': content_base64,
        'sha': sha
    }

    try:
        response = requests.put(url, headers=headers, json=update_data)
        if response.status_code in [200, 201]:
            print("✅ Successfully updated GitHub data")
            
            # Очищаем локальный файл после успешной отправки
            with open(local_data_file, 'w') as f:
                json.dump([], f, indent=2)
            print("🧹 Cleared local data file")
            
        else:
            print(f"❌ Failed to update: {response.status_code} - {response.text}")
    except requests.RequestException as e:
        print(f"❌ Error updating GitHub: {e}")

if __name__ == '__main__':
    main()
