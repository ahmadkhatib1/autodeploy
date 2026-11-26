# autodeploy — نشر تلقائي من GitLab أو GitHub إلى سيرفرك عبر n8n

[English](README.md) · **العربية**

عند كل `git push` على الفرع المحدد، يسحب السيرفر الكود ويبنيه ويشغّل النسخة الجديدة، ثم يرسل لك رسالة على تيليغرام أو البريد أو واتساب.

```
GitLab / GitHub push ──► n8n (Webhook) ──► SSH ──► trigger.sh ──► deploy.sh
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
- لكل مشروع رمز سري ومفتاح خاص به على GitLab أو GitHub (قراءة فقط).
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
sudo autodeploy add
```

شغّله بـ`sudo` لتكمل الأداة كل شيء بنفسها: تضيف مفتاح النشر والـwebhook عبر الـAPI (بعد أن تحفظ توكن، انظر أدناه)، وتنشئ قاعدة sudo لمشاريع script، ثم تشغّل أول نشر أو تجربة جافة.

سيسألك عن:

| السؤال | مثال |
|---|---|
| اسم المشروع | `hisabyy` |
| رابط المستودع | `git@gitlab.com:you/hisabyy.git` أو `https://github.com/you/site` (روابط https تُحوَّل تلقائياً) |
| المنصة | `gitlab` أو `github` (تُكتشف من الرابط) |
| الفرع | `main` |
| النوع | `node` (يعمل بـpm2)، أو `static` (ملفات فقط)، أو `script` (سكربت نشر خاص بك، انظر القسم 4ب) |
| أمر التثبيت | `auto` (يكتشف npm / pnpm / yarn / bun) |
| أمر البناء | `npm run build` |
| أمر التشغيل | `npm start` |
| المنفذ | `3000` (لا يتكرر بين مشروعين) |
| رابط الفحص | `http://127.0.0.1:3000` أو `none` |
| الإشعارات | فارغ = إعداد السيرفر، أو مثلاً `telegram` لهذا المشروع فقط |

ويمكنك تمرير كل الأجوبة كخيارات، فتصبح إضافة مشروع أمراً واحداً:

```bash
sudo autodeploy add --name shop --repo git@gitlab.com:me/shop.git --branch main \
  --type script --script /opt/shop/deploy/auto-deploy.sh --as-root yes \
  --health https://shop.example.com/health --yes
```

الخيارات: `--name --repo --provider --branch --type --install --build --start --port --health --script --as-root --rollback --notify`، و`--yes` لقبول القيم الافتراضية لما لم تحدده.

### الربط التلقائي مع GitLab / GitHub (موصى به)

احفظ توكن API لمنصتك مرة واحدة:

```bash
sudo autodeploy token set              # gitlab.com
sudo autodeploy token set github.com
sudo autodeploy token set gitlab.mycompany.com   # يعمل مع GitLab الخاص أيضاً
```

بعدها، `sudo autodeploy add` (و`sudo autodeploy connect <project>` للمشاريع الموجودة) يضيف لك **مفتاح النشر** للقراءة فقط و**الـwebhook** لأحداث الـpush فقط، ويتأكد أن المفتاح يقرأ الفرع. وإذا أعدت التشغيل يحدّث الـwebhook الموجود بدل أن يكرره.

| المنصة | التوكن المطلوب |
|---|---|
| GitLab | توكن شخصي أو توكن مجموعة أو مشروع، بصلاحية `api` ودور **Maintainer** على المشروع |
| GitHub | توكن fine-grained محصور بمستودعاتك، مع صلاحيتي **Administration** و**Webhooks** قراءة وكتابة (أو classic بصلاحيتي `repo` و`admin:repo_hook`) |

يُفحص التوكن قبل حفظه، ويُخزَّن لـroot فقط في `/etc/autodeploy/tokens/<host>.token` بصلاحية 600، ولا يُطبع أبداً ولا يمر في سطر الأوامر. و`autodeploy remove <project>` يحذف مفتاح النشر والـwebhook أيضاً. لإدارة التوكنات: `token list` و`token test [host]` و`token remove <host>`.

### الإعداد اليدوي

بدون توكن، تطبع لك الأداة بالضبط ما تلصقه حسب المنصة التي اخترتها:

**GitLab**

1. **Deploy key:** ضعه في **Settings ← Repository ← Deploy keys** (بدون صلاحية كتابة). السكربت ينتظرك ويتأكد أن الوصول يعمل.
2. **Webhook:** في **Settings ← Webhooks**:
   - URL: `https://n8n.example.com/webhook/deploy?project=hisabyy`
   - Secret token: الرمز الذي طبعه السكربت
   - Trigger: **Push events** فقط، مع فلتر الفرع `main`

**GitHub**

1. **Deploy key:** في **Settings ← Deploy keys ← Add deploy key**، والصق المفتاح، واترك خيار *Allow write access* غير مفعّل.
2. **Webhook:** في **Settings ← Webhooks ← Add webhook**:
   - Payload URL: `https://n8n.example.com/webhook/deploy?project=site&token=<الرمز>`
   - Content type: `application/json`
   - Secret: اتركه فارغاً
   - الأحداث: **Just the push event**

> GitHub لا يرسل الرمز في header بسيط مثل GitLab، لذلك الرمز جزء من الرابط. استخدم n8n عبر HTTPS (بدومين) حتى لا يُرسل الرمز مكشوفاً.

**متغيرات البيئة السرية للمشروع** (مثل `DATABASE_URL`) ضعها هنا، وستُربط بكل نسخة تلقائياً:

```bash
sudo -u deploy nano /opt/autodeploy/apps/hisabyy/shared/.env
```

(يُربط تلقائياً: `.env` و`.env.local` و`.env.production`. لتغيير القائمة أضف `SHARED_PATHS` في ملف المشروع.)

بعدها جرّب: ادفع commit، أو من GitLab اضغط **Test ← Push events** على الـwebhook. أما GitHub فيرسل رسالة ping عند إنشاء الـwebhook، وn8n يتجاهلها، وأول push بعدها يبدأ النشر.

## 4ب) خيار: سكربت نشر خاص بك (Docker Compose، ترحيلات، نسخ احتياطي)

إذا كان مشروعك يحتاج أكثر من "تثبيت ← بناء ← تشغيل"، مثل مشروع يعمل بـ`docker compose`، أو يحتاج نسخة احتياطية وترحيلات قاعدة بيانات قبل كل نشر، فاختر النوع **`script`**. تبقى autodeploy مسؤولة عن الـwebhook والتحقق والقفل والسجل والإشعارات، لكنها تشغّل **سكربتك أنت** بدل البناء الخاص بها، وتشغّله كـroot عند الحاجة عبر قاعدة sudo محصورة بهذا الملف فقط.

**شروط السكربت:**

| | |
|---|---|
| النشر | يُستدعى **بدون وسائط** |
| التجربة الجافة | يُستدعى بـ **`--dry-run`**: يعرض الخطة ولا يغيّر شيئاً |
| النتيجة | الخروج بـ **0** = نجح النشر؛ أي رمز آخر = فشل، وآخر 25 سطراً من مخرجاته تصلك في إشعار ❌ |
| المسؤولية | السكربت نفسه يسحب الكود ويبني ويرحّل ويعيد التشغيل، **ويرجع بنفسه** عند الفشل |
| المتغيرات | عبر sudo لا يصله أي متغير بيئة، فاجعل إعداداته داخله |

> إذا كان سكربتك الحالي يقرأ `DRY_RUN=1` من البيئة، يكفي أن تضيف في أوله:
> `[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1`

**الخطوات:**

1. ضع السكربت في المستودع (مثلاً `deploy/auto-deploy.sh`)، واسحبه على السيرفر، ثم اجعله مملوكاً لـroot ولا يعدّله غيره:
   ```bash
   cd /opt/myapp && git pull --ff-only
   sudo chown root:root deploy/auto-deploy.sh
   sudo chmod 750 deploy/auto-deploy.sh
   ```
2. سجّل المشروع بـ `sudo autodeploy add` واختر:

   | السؤال | الجواب |
   |---|---|
   | App type | **`script`** |
   | Deploy script | `/opt/myapp/deploy/auto-deploy.sh` |
   | Run it as root through sudo? | `yes` (لـDocker والنسخ الاحتياطي…) أو `no` |
   | Rollback script | مسار سكربت رجوع، أو `none` |
   | Healthcheck URL | اختياري، فحص إضافي بعد نجاح السكربت |

   ولأنك شغّلته بـsudo، يقوم بأمرين تلقائياً:
   - **ينشئ قاعدة sudo** في `/etc/sudoers.d/autodeploy-myapp`، بعد أن يتأكد أن السكربت ملف عادي مملوك لـroot، ولا يستطيع غيره تعديله ولا تعديل المجلدات التي فوقه. القاعدة تسمح فقط بتشغيل السكربت بدون وسائط أو بـ`--dry-run`، ولا شيء غير ذلك. إن غيّرت الصلاحيات لاحقاً نفّذ: `sudo autodeploy allow-sudo myapp`.
   - **يعرض عليك تجربة جافة** فوراً.
3. أضف مفتاح Deploy key والـwebhook في GitLab أو GitHub كأي مشروع آخر.
4. جرّب:
   ```bash
   autodeploy deploy myapp --dry-run   # يشغّل سكربتك بـ --dry-run
   autodeploy deploy myapp             # نشر فعلي الآن
   ```

**الرجوع:** لا توجد نسخ محفوظة عند autodeploy في هذا النوع. لذلك `autodeploy rollback myapp` يشغّل `ROLLBACK_SCRIPT` إن حدّدته، وإلا يوضّح لك أن الرجوع مسؤولية سكربتك، أو أن تستخدم `git revert` ثم push.

**تنبيه أمني:** عندما يعمل السكربت كـroot ويأتي من المستودع نفسه، فإن **أي شخص يستطيع الدفع إلى الفرع المنشور يملك عملياً صلاحية root على السيرفر**. احمِ الفرع في GitLab أو GitHub، وحدّد من يملك صلاحية الدفع، أو انشر من فرع مخصص مثل `production`. وعند `autodeploy remove` تُلغى قاعدة sudo تلقائياً.

قالب جاهز لـDocker Compose: [`examples/deploy-script-template.sh`](examples/deploy-script-template.sh)، والدليل الكامل بالإنجليزية: [docs/custom-script.md](docs/custom-script.md).

## 5) الأوامر

```bash
sudo autodeploy add [خيارات]       # تسجيل مشروع (يسأل عمّا لم تحدده)
sudo autodeploy connect hisabyy    # إنشاء مفتاح النشر والـwebhook عبر الـAPI من جديد، وقاعدة sudo، وأول تشغيل
sudo autodeploy token set [host]   # حفظ توكن GitLab / GitHub (وأيضاً list وtest وremove)
autodeploy list                    # المشاريع والنسخة الحالية لكل منها
autodeploy deploy hisabyy          # نشر يدوي الآن
autodeploy deploy hisabyy --dry-run      # لمشاريع script: عرض الخطة فقط
autodeploy rollback hisabyy        # الرجوع للنسخة السابقة
sudo autodeploy allow-sudo hisabyy       # لمشاريع script: إنشاء قاعدة sudo من جديد
autodeploy logs hisabyy            # آخر سجل نشر
sudo autodeploy remove hisabyy     # إلغاء تسجيل مشروع، ومع التوكن يحذف المفتاح والـwebhook (الملفات تبقى)
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
├── keys/           مفاتيح GitLab / GitHub لكل مشروع
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
- كل مشروع له رمز webhook خاص ومفتاح للقراءة فقط على GitLab أو GitHub.
- ملفات الأسرار بصلاحية `600` ومملوكة للمستخدم `deploy`.

## 9) حل المشاكل

| المشكلة | الحل |
|---|---|
| لا يصل شيء عند الـpush | في GitLab افتح الـwebhook ← **Recent events**، وفي GitHub ← **Recent Deliveries**، وانظر رمز الاستجابة. ثم في n8n افتح **Executions**. |
| الـexecution يقول `ERR unauthorized` | الرمز (Secret token في GitLab، أو `token=` في رابط GitHub) لا يطابق `DEPLOY_TOKEN` في ملف المشروع. |
| `SKIP branch` | الـpush على فرع غير المحدد للمشروع. |
| فشل `git fetch` | الـDeploy key غير مضاف أو غير مفعّل لهذا المستودع. |
| فشل فحص الموقع | التطبيق لا يستمع على `PORT`. افحص `app.err.log`. يمكن زيادة `HEALTHCHECK_TIMEOUT` (بالثواني) في ملف المشروع. |
| n8n لا يتصل بـSSH | تأكد أن `sshd` يعمل وأن الجدار الناري يسمح بالمنفذ 22 من شبكة Docker. |

## مراجع إضافية

- [كل إعدادات المشروع](docs/configuration.md)
- [سكربت النشر الخاص (APP_TYPE=script)](docs/custom-script.md)
- [كيف تعمل الأداة والأمان](docs/how-it-works.md)
- [إعداد الإشعارات بالتفصيل](docs/notifications.md)

## ملاحظة

هذه الأداة لا تضبط دومين لكل تطبيق (Nginx أو Caddy أمام المنافذ). هذه الخطوة تُضاف لاحقاً لكل مشروع.
