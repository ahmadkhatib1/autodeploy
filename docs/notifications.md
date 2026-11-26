# Notifications

Choose channels during install, or any time later:

```bash
autodeploy notify-setup   # pick channels and enter credentials
autodeploy notify-test    # send a test message
```

Settings live in `/opt/autodeploy/config/notify.env` (mode 600). To use different channels for one project, add to its file:

```
NOTIFY_CHANNELS='telegram'
```

A channel that fails (wrong token, no network) only logs a warning. It never fails the deploy.

## What you receive

- ✅ **Deployed**: project, branch, commit, message, author, duration.
- ❌ **Failed**: the same, plus the step that failed, whether the site was rolled back, the last 25 log lines and the log path.
- ↩️ **Manual rollback**: which release is live now.

## Telegram

1. In Telegram, open **@BotFather** → `/newbot` → copy the token.
2. Send any message to your new bot.
3. Open `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy `message.chat.id`.
   For a group, add the bot to the group, send a message there, and use the (negative) group id.

```
TG_BOT_TOKEN='123456:ABC…'
TG_CHAT_ID='123456789'
```

## Email (SMTP)

Any SMTP server works. Port `465` uses implicit TLS; `587` uses STARTTLS. TLS is always required.

**Gmail**: turn on 2-Step Verification, then create an **App password** (Google Account → Security → App passwords) and use it instead of your normal password.

```
SMTP_HOST='smtp.gmail.com'
SMTP_PORT='465'
SMTP_USER='you@gmail.com'
SMTP_PASS='abcd efgh ijkl mnop'
SMTP_FROM='you@gmail.com'
EMAIL_TO='you@gmail.com, teammate@example.com'
```

## WhatsApp

Two providers:

### `cloud`: official WhatsApp Cloud API (Meta)

1. Create an app at developers.facebook.com and add the **WhatsApp** product.
2. From **API Setup**, copy the **Phone number ID**, and create a permanent token (System User in Business Settings).
3. Add your own number as a recipient.

```
WA_PROVIDER='cloud'
WA_PHONE_NUMBER_ID='1234567890'
WA_TOKEN='EAAG…'
WA_TO='9639xxxxxxxx'
```

> Meta only delivers free-form text if the recipient messaged the business number in the last 24 hours. Outside that window you need an approved message template. Sending "hi" to the number once a day keeps the window open.

### `callmebot`: free, personal use

Follow the activation steps on callmebot.com (WhatsApp section) to receive an API key, then:

```
WA_PROVIDER='callmebot'
WA_TO='9639xxxxxxxx'
CALLMEBOT_APIKEY='123456'
```
