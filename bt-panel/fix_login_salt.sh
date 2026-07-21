#!/bin/bash
# fix_login_salt.sh - Fix BT Panel login failure caused by chdck_salt()
#
# Problem: BT Panel's chdck_salt() function regenerates salt and re-hashes
# the password on startup if it detects salt is NULL. This corrupts the
# password because it treats the existing hash as plaintext.
#
# Symptom: "用户名或密码错误" despite correct credentials
#
# Solution: Use the panel's own Python ORM to set the correct password hash
#
# Usage:
#   bash fix_login_salt.sh <username> <password>
#
# Example:
#   bash fix_login_salt.sh admin MyPassword123

set -e

USERNAME="${1:-admin}"
PASSWORD="${2:-}"
PANEL_PATH="/www/server/panel"
PANEL_PYTHON="${PANEL_PATH}/pyenv/bin/python3"

if [ -z "$PASSWORD" ]; then
    echo "Usage: bash fix_login_salt.sh <username> <password>"
    echo "Example: bash fix_login_salt.sh admin MyPassword123"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Must run as root"
    exit 1
fi

if [ ! -f "$PANEL_PYTHON" ]; then
    echo "Error: BT Panel Python not found at $PANEL_PYTHON"
    exit 1
fi

echo "[*] Fixing BT Panel login for user: $USERNAME"

# Use the panel's own Python ORM to set the correct password
# This ensures the database state is consistent with what the panel reads
$PANEL_PYTHON -c "
import sys, hashlib
sys.path.insert(0, '${PANEL_PATH}')
sys.path.insert(0, '${PANEL_PATH}/class')
import public, db

def md5(s):
    if isinstance(s, str): s = s.encode()
    return hashlib.md5(s).hexdigest()

username = '${USERNAME}'
password = '${PASSWORD}'

sql = db.Sql()
user = sql.table('users').where('username=?', (username,)).find()

if not user:
    print('[!] User not found, creating...')
    import secrets, string
    salt = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12))
    post_password = md5(md5(password) + '_bt.cn')
    db_password = md5(post_password + salt)
    sql.table('users').insert({
        'username': username,
        'password': db_password,
        'salt': salt
    })
    print(f'[+] User created: {username}')
    print(f'[+] Salt: {salt}')
    print(f'[+] Password hash: {db_password}')
else:
    print(f'[*] Current salt: {user[\"salt\"]}')
    print(f'[*] Current password hash: {user[\"password\"]}')

    # Use existing salt (chdck_salt may have changed it)
    salt = user['salt']
    if not salt:
        # Generate new salt if NULL
        import secrets, string
        salt = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12))
        print(f'[+] Generated new salt: {salt}')

    # Calculate correct password hash
    # Frontend sends: md5(md5(password) + '_bt.cn')
    # Database stores: md5(frontend_password + salt)
    post_password = md5(md5(password) + '_bt.cn')
    correct_db_password = md5(post_password + salt)

    print(f'[*] Correct password hash: {correct_db_password}')

    if user['password'] == correct_db_password:
        print('[*] Password is already correct!')
    else:
        sql.table('users').where('username=?', (username,)).update({
            'password': correct_db_password,
            'salt': salt
        })
        print('[+] Password updated successfully!')

# Verify
user_after = sql.table('users').where('username=?', (username,)).find()
post_password = md5(md5(password) + '_bt.cn')
verify = md5(post_password + user_after['salt'])
if verify == user_after['password']:
    print('[OK] Verification passed - login should work now')
else:
    print('[FAIL] Verification failed - something went wrong')
    sys.exit(1)
"

if [ $? -eq 0 ]; then
    echo ""
    echo "[*] Clearing session files..."
    rm -f ${PANEL_PATH}/data/session/* 2>/dev/null || true

    echo "[*] Restarting BT Panel..."
    pkill -f "BT-Panel" 2>/dev/null || true
    sleep 2
    cd ${PANEL_PATH} && ${PANEL_PYTHON} ${PANEL_PATH}/BT-Panel &
    sleep 3

    echo ""
    echo "========================================="
    echo " BT Panel login fixed!"
    echo " Username: $USERNAME"
    echo " Password: $PASSWORD"
    echo "========================================="
    echo ""
    echo "Note: Always use this script to reset BT Panel passwords."
    echo "      Do NOT use sqlite3 CLI - it may read inconsistent data."
fi
