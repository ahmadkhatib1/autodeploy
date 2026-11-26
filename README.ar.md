# autodeploy — نشر تلقائي من GitLab إلى سيرفرك عبر n8n

[English](README.md) · **العربية**

عند كل `git push` على الفرع المحدد، يسحب السيرفر الكود ويبنيه ويشغّل النسخة الجديدة، ثم يرسل لك رسالة على تيليغرام أو البريد أو واتساب.

```
GitLab push ──► n8n (Webhook) ──► SSH ──► trigger.sh ──► deploy.sh
                                                          ├─ git fetch
                                                          ├─ install + build في مجلد جديد
                                                          ├─ تبديل النسخة (بدون توقف)
                                                          ├─ pm2 restart + فحص الموقع
                                                          └─ إشعار ✅ / ❌
```

**ميزات:**
- أداة واحدة على السيرفر، وكل مشروع يُضاف بأمر واحد: `autodeploy add`.
- كل نشر في مجلد مستقل. إذا فشل البناء لا يتغير الموقع أبداً.
- إذا نجح البناء وفشل فحص الموقع بعد التشغيل، يرجع تلقائياً إلى النسخة السابقة.
- رجوع يدوي بأمر واحد: `autodeploy rollback <project>`.
- لكل مشروع رمز سري ومفتاح GitLab خاص به (قراءة فقط).
- مفتاح n8n لا يستطيع تنفيذ أي شيء على السيرفر إلا سكربت النشر.

---

## 1) المتطلبات

- سيرفر Ubuntu 22.04 أو 24.04 (أو Debian) ودخول root.
- اختياري لكن موصى به: دومين لـn8n مثل `n8n.example.com` يشير إلى IP السيرفر (سجل A)، لتعمل الروابط عبر HTTPS.

## 2) التنصيب (مرة واحدة)

اختر إحدى الطريقتين على السيرفر:

**عبر npm** (إذا كان Node.js 18 أو أحدث مثبتاً):

```bash
sudo npx @ahmadkhatib/autodeploy install
```

**عبر Git** (لا يحتاج Node، والسكربت يثبّته بنفسه):

```bash
git clone https://github.com/ahmadkhatib1/autodeploy.git
cd autodeploy
sudo bash install.sh
```

السكربت يثبّت: Git، وDocker، وNode.js 22، وpm2، وn8n (داخل Docker). ثم يسألك:

1. **دومين n8n:** اكتبه، أو اتركه فارغاً ليعمل على `http://SERVER_IP:5678`.
2. **قنوات الإشعارات:** يسألك عن كل قناة (تيليغرام، بريد، واتساب). اختر واحدة أو أكثر، ثم يرسل رسالة تجربة.

## 3) إكمال n8n (مرة واحدة، 3 دقائق)

في نهاية التنصيب يطبع السكربت هذه الخطوات مع المفتاح:

1. افتح رابط n8n وأنشئ حساب المالك.
2. **Credentials ← Add credential ← SSH Private Key:**
   - Name: `autodeploy server`
   - Host: `host.docker.internal`، Port: `22`، Username: `deploy`
   - Private Key: المفتاح الذي طبعه السكربت (يمكنك عرضه مجدداً بـ `sudo cat /opt/autodeploy/n8n/n8n_ssh_key`).
3. **استيراد الـworkflow:** على السيرفر نفّذ `cat /opt/autodeploy/n8n/workflow.json`، وانسخ الناتج، ثم الصقه داخل لوحة n8n الفارغة بـ Ctrl+V.
4. افتح عقدة **Run deploy on server**، واختر الـcredential `autodeploy server`، واحفظ، ثم فعّل الـworkflow (**Active**).

## 4) إضافة مشروع (لكل مشروع)

```bash
autodeploy add
```

سيسألك عن:

| السؤال | مثال |
|---|---|
| اسم المشروع | `hisabyy` |
| رابط GitLab | `git@gitlab.com:you/hisabyy.git` (أو رابط https وسيحوّله) |
| الفرع | `main` |
| النوع | `node` (يعمل بـpm2) أو `static` (ملفات فقط) |
| أمر التثبيت | `auto` (يكتشف npm / pnpm / yarn / bun) |
| أمر البناء | `npm run build` |
| أمر التشغيل | `npm start` |
| المنفذ | `3000` (لا يتكرر بين مشروعين) |
| رابط الفحص | `http://127.0.0.1:3000` أو `none` |
| الإشعارات | فارغ = إعداد السيرفر، أو مثلاً `telegram` لهذا المشروع فقط |

ثم يعطيك شيئين تلصقهما في GitLab:

1. **Deploy key:** ضعه في **Settings ← Repository ← Deploy keys** (بدون صلاحية كتابة). السكربت ينتظرك ويتأكد أن الوصول يعمل.
2. **Webhook:** في **Settings ← Webhooks**:
   - URL: `https://n8n.example.com/webhook/deploy?project=hisabyy`
   - Secret token: الرمز الذي طبعه السكربت
   - Trigger: **Push events** فقط، مع فلتر الفرع `main`

**متغيرات البيئة السرية للمشروع** (مثل `DATABASE_URL`) ضعها هنا، وستُربط بكل نسخة تلقائياً:

```bash
sudo -u deploy nano /opt/autodeploy/apps/hisabyy/shared/.env
```

(يُربط تلقائياً: `.env` و`.env.local` و`.env.production`. لتغيير القائمة أضف `SHARED_PATHS` في ملف المشروع.)

بعدها جرّب: ادفع commit، أو من GitLab اضغط **Test ← Push events** على الـwebhook.

## 5) الأوامر

```bash
autodeploy list                    # المشاريع والنسخة الحالية لكل منها
autodeploy deploy hisabyy          # نشر يدوي الآن
autodeploy rollback hisabyy        # الرجوع للنسخة السابقة
autodeploy logs hisabyy            # آخر سجل نشر
autodeploy remove hisabyy          # إلغاء تسجيل مشروع (الملفات تبقى)
autodeploy notify-setup            # تغيير قنوات الإشعارات
autodeploy notify-test             # رسالة تجربة
autodeploy info                    # المسارات ورابط الـwebhook
```

سجلات التطبيق نفسه: `/opt/autodeploy/logs/<project>/app.out.log` و`app.err.log`، أو `sudo -u deploy pm2 logs <project>`.

## 6) إعداد الإشعارات

يمكنك تغييرها في أي وقت بـ `autodeploy notify-setup`. ولمشروع معيّن، أضف في ملفه `/opt/autodeploy/projects/<name>.env` السطر `NOTIFY_CHANNELS='telegram'` مثلاً.

**تيليغرام**
1. افتح `@BotFather`، وأرسل `/newbot`، وانسخ الـtoken.
2. أرسل أي رسالة لبوتك، ثم افتح `https://api.telegram.org/bot<TOKEN>/getUpdates` وانسخ قيمة `chat.id`.

**البريد**
- يعمل أي حساب SMTP. مع Gmail: الخادم `smtp.gmail.com`، والمنفذ `465`، وكلمة مرور تطبيق (App Password) من إعدادات أمان حساب Google، وليس كلمة السر العادية.

**واتساب** (خياران)
- `cloud`: الـAPI الرسمي من Meta. يحتاج حساب مطوّر وتطبيق WhatsApp ورقم مُعرّف (Phone number ID) وtoken. ملاحظة: الرسائل النصية الحرّة تصل فقط إذا راسلت رقم البوت خلال آخر 24 ساعة؛ خارج ذلك تطلب Meta قوالب معتمدة.
- `callmebot`: مجاني وسريع للاستخدام الشخصي فقط. فعّله من موقع callmebot.com لتحصل على API key.

## 7) هيكل الملفات على السيرفر

```
/opt/autodeploy/
├── bin/            السكربتات (autodeploy, deploy.sh, trigger.sh, ...)
├── lib/            الدوال المشتركة والإشعارات
├── config/         notify.env, server.env (صلاحيات 600)
├── projects/       <name>.env  إعدادات ورمز كل مشروع
├── keys/           مفاتيح GitLab لكل مشروع
├── apps/<name>/
│   ├── current ->  releases/<آخر نسخة>
│   ├── releases/   آخر 5 نسخ
│   └── shared/     .env والملفات الدائمة
├── logs/<name>/    سجل كل عملية نشر
└── n8n/            docker-compose.yml و workflow.json
```

## 8) الأمان

- مفتاح n8n مقيّد في `authorized_keys` بأمر واحد (`trigger.sh`)، ومن شبكات Docker فقط، بلا terminal ولا port forwarding.
- `trigger.sh` لا ينفّذ أي شيء من الطلب: يتحقق من اسم المشروع والرمز والفرع بأنماط صارمة، ثم يشغّل النشر.
- كل مشروع له رمز webhook خاص ومفتاح GitLab للقراءة فقط.
- ملفات الأسرار بصلاحية `600` ومملوكة للمستخدم `deploy`.

## 9) حل المشاكل

| المشكلة | الحل |
|---|---|
| لا يصل شيء عند الـpush | في GitLab افتح الـwebhook ← **Recent events** وانظر رمز الاستجابة. في n8n افتح **Executions**. |
| الـexecution يقول `ERR unauthorized` | الـSecret token في GitLab لا يطابق `DEPLOY_TOKEN` في ملف المشروع. |
| `SKIP branch` | الـpush على فرع غير المحدد للمشروع. |
| فشل `git fetch` | الـDeploy key غير مضاف أو غير مفعّل لهذا المشروع في GitLab. |
| فشل فحص الموقع | التطبيق لا يستمع على `PORT`. افحص `app.err.log`. يمكن زيادة `HEALTHCHECK_TIMEOUT` (بالثواني) في ملف المشروع. |
| n8n لا يتصل بـSSH | تأكد أن `sshd` يعمل وأن الجدار الناري يسمح بالمنفذ 22 من شبكة Docker. |

## مراجع إضافية

- [كل إعدادات المشروع](docs/configuration.md)
- [كيف تعمل الأداة والأمان](docs/how-it-works.md)
- [إعداد الإشعارات بالتفصيل](docs/notifications.md)

## ملاحظة

هذه الأداة لا تضبط دومين لكل تطبيق (Nginx أو Caddy أمام المنافذ). هذه الخطوة تُضاف لاحقاً لكل مشروع.
