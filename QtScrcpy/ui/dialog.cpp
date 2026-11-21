#include <QDebug>
#include <QAbstractItemView>
#include <QDesktopServices>
#include <QDateTime>
#include <QCheckBox>
#include <QDir>
#include <QFile>
#include <QFileDialog>
#include <QFrame>
#include <QFileInfo>
#include <QFormLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QLabel>
#include <QComboBox>
#include <QBrush>
#include <QColor>
#include <QLineEdit>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPainter>
#include <QPushButton>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QSettings>
#include <QSizePolicy>
#include <QScreen>
#include <QScrollArea>
#include <QSet>
#include <QStackedWidget>
#include <QStandardPaths>
#include <QStyledItemDelegate>
#include <QSpinBox>
#include <QSslCertificate>
#include <QSslConfiguration>
#include <QSslSocket>
#include <QTabWidget>
#include <QTime>
#include <QTimer>
#include <QVBoxLayout>
#include <QUrl>

#include "config.h"
#include "dialog.h"
#include "ui_dialog.h"
#include "videoform.h"
#include "../groupcontroller/groupcontroller.h"

#ifdef Q_OS_WIN32
#include "../util/winutils.h"
#endif

QString s_keyMapPath = "";
QString s_defaultKeyMapPath = "";

namespace {
class ComboBoxItemDelegate final : public QStyledItemDelegate
{
public:
    explicit ComboBoxItemDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}

    QSize sizeHint(const QStyleOptionViewItem &option, const QModelIndex &index) const override
    {
        QSize hint = QStyledItemDelegate::sizeHint(option, index);
        hint.setHeight(qMax(hint.height(), 30));
        return hint;
    }
};

enum DeviceItemRole {
    DeviceModelRole = Qt::UserRole + 1,
    DeviceOnlineRole,
    DeviceBatteryRole,
    DeviceChargingRole,
    DeviceNetworkRole,
    DeviceScreenRole,
    DeviceSeenRole
};

class DevicePresenceDelegate final : public QStyledItemDelegate
{
public:
    explicit DevicePresenceDelegate(QObject *parent = nullptr) : QStyledItemDelegate(parent) {}

    QSize sizeHint(const QStyleOptionViewItem &option, const QModelIndex &) const override
    {
        return QSize(option.rect.width(), 132);
    }

    void paint(QPainter *painter, const QStyleOptionViewItem &option,
               const QModelIndex &index) const override
    {
        painter->save();
        painter->setRenderHint(QPainter::Antialiasing, true);
        const QRect card = option.rect.adjusted(4, 4, -4, -4);
        const bool selected = (option.state & QStyle::State_Selected) != 0;
        painter->setPen(QPen(selected ? QColor(QStringLiteral("#4687cf"))
                                  : QColor(QStringLiteral("#324257")), 1));
        painter->setBrush(selected ? QColor(QStringLiteral("#243a55"))
                                   : QColor(QStringLiteral("#1b2738")));
        painter->drawRoundedRect(card, 11, 11);

        if (index.data(Qt::UserRole).toString().isEmpty()) {
            painter->setPen(QColor(QStringLiteral("#a0b2ca")));
            painter->drawText(card, Qt::AlignCenter,
                              QStringLiteral("Nenhum dispositivo disponível"));
            painter->restore();
            return;
        }

        const bool online = index.data(DeviceOnlineRole).toBool();
        const QColor presenceColor(online ? QStringLiteral("#35d09a")
                                          : QStringLiteral("#f16c78"));
        const int left = card.left() + 14;
        const int right = card.right() - 14;
        const int availableWidth = qMax(0, right - left);
        painter->setPen(Qt::NoPen);
        painter->setBrush(presenceColor);
        painter->drawEllipse(QRect(left, card.top() + 16, 9, 9));

        QFont heading = option.font;
        heading.setBold(true);
        heading.setPointSize(10);
        painter->setFont(heading);
        painter->setPen(QColor(QStringLiteral("#f0f4fa")));
        const QString model = index.data(DeviceModelRole).toString();
        const QString shownModel = model.isEmpty() ? QStringLiteral("Android") : model;
        const int headingWidth = qMax(25, availableWidth - 122);
        painter->drawText(QRect(left + 19, card.top() + 8, headingWidth, 25),
                          Qt::AlignVCenter | Qt::AlignLeft,
                          QFontMetrics(heading).elidedText(shownModel, Qt::ElideRight, headingWidth));

        QFont small = option.font;
        small.setPointSize(8);
        small.setBold(true);
        painter->setFont(small);
        painter->setPen(presenceColor);
        painter->drawText(QRect(right - 94, card.top() + 8, 94, 25),
                          Qt::AlignVCenter | Qt::AlignRight,
                          online ? QStringLiteral("ONLINE") : QStringLiteral("OFFLINE"));

        small.setBold(false);
        painter->setFont(small);
        painter->setPen(QColor(QStringLiteral("#9baec6")));
        const QString deviceId = index.data(Qt::UserRole).toString();
        const QString shortId = deviceId.left(8) + (deviceId.size() > 8
                                                    ? QStringLiteral("…") : QString());
        painter->drawText(QRect(left + 19, card.top() + 34, availableWidth - 19, 18),
                          Qt::AlignVCenter | Qt::AlignLeft,
                          QStringLiteral("ID  ") + shortId);

        painter->setPen(QColor(QStringLiteral("#35465e")));
        const int separatorY = card.top() + 59;
        painter->drawLine(left, separatorY, right, separatorY);

        QFont detail = option.font;
        detail.setPointSize(9);
        painter->setFont(detail);
        painter->setPen(QColor(QStringLiteral("#d9e3f1")));
        const int columnWidth = qMax(30, availableWidth / 2);
        const int secondColumn = left + columnWidth;
        const int y1 = card.top() + 66;
        const int y2 = card.top() + 91;
        const int battery = index.data(DeviceBatteryRole).toInt();
        const bool charging = index.data(DeviceChargingRole).toBool();
        const QString batteryText = battery >= 0
                ? QStringLiteral("%1%  ·  %2").arg(battery).arg(charging
                    ? QStringLiteral("Carregando") : QStringLiteral("Bateria"))
                : QStringLiteral("Bateria  --");
        const QString network = index.data(DeviceNetworkRole).toString();
        QString networkText;
        if (network == QLatin1String("wifi")) networkText = QStringLiteral("Wi-Fi");
        else if (network == QLatin1String("cellular")) networkText = QStringLiteral("Rede móvel");
        else if (network == QLatin1String("ethernet")) networkText = QStringLiteral("Ethernet");
        else if (network == QLatin1String("none")) networkText = QStringLiteral("Sem rede");
        else networkText = QStringLiteral("Rede  --");
        const QVariant screen = index.data(DeviceScreenRole);
        const QString screenText = !screen.isValid()
                ? QStringLiteral("Tela  --")
                : (screen.toBool() ? QStringLiteral("Tela ligada") : QStringLiteral("Tela desligada"));
        const QString seenText = index.data(DeviceSeenRole).toString();

        const auto drawDetail = [&](const QString &value, int x, int y, int width) {
            const int innerWidth = qMax(12, width - 8);
            painter->drawText(QRect(x, y, innerWidth, 20),
                              Qt::AlignVCenter | Qt::AlignLeft,
                              QFontMetrics(detail).elidedText(value, Qt::ElideRight, innerWidth));
        };
        drawDetail(batteryText, left, y1, columnWidth);
        drawDetail(networkText, secondColumn, y1, columnWidth);
        drawDetail(screenText, left, y2, columnWidth);
        drawDetail(seenText.isEmpty() ? QStringLiteral("Último visto: --") : seenText,
                   secondColumn, y2, columnWidth);
        painter->restore();
    }
};

QString lastSeenSummary(const QString &value)
{
    const QDateTime seen = QDateTime::fromString(value, Qt::ISODate);
    if (!seen.isValid()) return QStringLiteral("Último visto: --");
    const qint64 seconds = seen.secsTo(QDateTime::currentDateTimeUtc());
    if (seconds < 0) return QStringLiteral("Último visto: agora");
    if (seconds < 60) return QStringLiteral("Visto agora");
    if (seconds < 3600) return QStringLiteral("Visto há %1 min").arg(seconds / 60);
    if (seconds < 86400) return QStringLiteral("Visto há %1 h").arg(seconds / 3600);
    return QStringLiteral("Visto %1").arg(seen.toLocalTime().toString(QStringLiteral("dd/MM HH:mm")));
}
} // namespace

const QString &getKeyMapPath()
{
    if (s_keyMapPath.isEmpty()) {
        s_keyMapPath = QString::fromLocal8Bit(qgetenv("QTSCRCPY_KEYMAP_PATH"));
        if (s_keyMapPath.isEmpty()) {
            s_keyMapPath = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation) + "/keymap";
        }
        if (!QDir().mkpath(s_keyMapPath)) {
            qWarning() << "Failed to create keymap directory:" << s_keyMapPath;
        }
    }
    return s_keyMapPath;
}

const QString &getDefaultKeyMapPath()
{
    if (s_defaultKeyMapPath.isEmpty()) {
        s_defaultKeyMapPath = QString::fromLocal8Bit(qgetenv("QTSCRCPY_DEFAULT_KEYMAP_PATH"));
        if (s_defaultKeyMapPath.isEmpty()) {
            s_defaultKeyMapPath = QCoreApplication::applicationDirPath() + "/keymap";
        }
    }
    return s_defaultKeyMapPath;
}

void initializeKeyMapDirectory()
{
    const QDir defaultDir(getDefaultKeyMapPath());
    const QDir userDir(getKeyMapPath());
    if (!defaultDir.exists() || !userDir.exists()) {
        return;
    }

    const QFileInfoList defaults = defaultDir.entryInfoList(QStringList() << "*.json", QDir::Files);
    for (const QFileInfo &fileInfo : defaults) {
        const QString userFile = userDir.filePath(fileInfo.fileName());
        if (!QFileInfo::exists(userFile) && !QFile::copy(fileInfo.filePath(), userFile)) {
            qWarning() << "Failed to copy default keymap to:" << userFile;
        }
    }
}

Dialog::Dialog(QWidget *parent) : QWidget(parent), ui(new Ui::Widget)
{
    ui->setupUi(this);

    initializeKeyMapDirectory();
    initUI();


    updateBootConfig(true);


    // Intel Mac 上如果配置文件遗留 decodeMode=1，强制重置为 0
    // （VideoToolbox 选项在 initUI() 中已被移除）
#if defined(Q_OS_MACOS) && !defined(__arm64__)
    if (ui->decodeModeBox->currentIndex() != 0) {
        ui->decodeModeBox->setCurrentIndex(0);
    }
#endif

    on_useSingleModeCheck_clicked();

    if (QScreen *screen = QGuiApplication::primaryScreen()) {
        const QRect availableGeometry = screen->availableGeometry();
        move(availableGeometry.x() + (availableGeometry.width() - width()) / 2,
             availableGeometry.y() + (availableGeometry.height() - height()) / 2);
    }
    on_updateDevice_clicked();


    connect(&m_autoUpdatetimer, &QTimer::timeout, this, &Dialog::on_updateDevice_clicked);
    if (ui->autoUpdatecheckBox->isChecked()) {
        m_autoUpdatetimer.start(5000);
    }

    connect(&m_adb, &qsc::AdbProcess::adbProcessResult, this, [this](qsc::AdbProcess::ADB_EXEC_RESULT processResult) {
        QString log = "";
        bool newLine = true;
        QStringList args = m_adb.arguments();

        switch (processResult) {
        case qsc::AdbProcess::AER_ERROR_START:
            break;
        case qsc::AdbProcess::AER_SUCCESS_START:
            log = "adb run";
            newLine = false;
            break;
        case qsc::AdbProcess::AER_ERROR_EXEC:
            //log = m_adb.getErrorOut();
            if (args.contains("ifconfig") && args.contains("wlan0")) {
                getIPbyIp();
            }
            break;
        case qsc::AdbProcess::AER_ERROR_MISSING_BINARY:
            log = "adb not found";
            break;
        case qsc::AdbProcess::AER_SUCCESS_EXEC:
            //log = m_adb.getStdOut();
            if (args.contains("devices")) {
                QStringList devices = m_adb.getDevicesSerialFromStdOut();
                ui->serialBox->clear();
                ui->connectedPhoneList->clear();
                for (auto &item : devices) {
                    ui->serialBox->addItem(item);
                    ui->connectedPhoneList->addItem(Config::getInstance().getNickName(item) + "-" + item);
                }
            } else if (args.contains("show") && args.contains("wlan0")) {
                QString ip = m_adb.getDeviceIPFromStdOut();
                if (ip.isEmpty()) {
                    log = "ip not find, connect to wifi?";
                    break;
                }
                ui->deviceIpEdt->setEditText(ip);
            } else if (args.contains("ifconfig") && args.contains("wlan0")) {
                QString ip = m_adb.getDeviceIPFromStdOut();
                if (ip.isEmpty()) {
                    log = "ip not find, connect to wifi?";
                    break;
                }
                ui->deviceIpEdt->setEditText(ip);
            } else if (args.contains("ip -o a")) {
                QString ip = m_adb.getDeviceIPByIpFromStdOut();
                if (ip.isEmpty()) {
                    log = "ip not find, connect to wifi?";
                    break;
                }
                ui->deviceIpEdt->setEditText(ip);
            }
            break;
        }
        if (!log.isEmpty()) {
            outLog(log, newLine);
        }
    });

    m_hideIcon = new QSystemTrayIcon(this);
    m_hideIcon->setIcon(QIcon(":/image/tray/logo.png"));
    m_menu = new QMenu(this);
    m_quit = new QAction(this);
    m_showWindow = new QAction(this);
    m_showWindow->setText(tr("show"));
    m_quit->setText(tr("quit"));
    m_menu->addAction(m_showWindow);
    m_menu->addAction(m_quit);
    m_hideIcon->setContextMenu(m_menu);
    m_hideIcon->show();
    connect(m_showWindow, &QAction::triggered, this, &Dialog::show);
    connect(m_quit, &QAction::triggered, this, [this]() {
        m_hideIcon->hide();
        qApp->quit();
    });
    connect(m_hideIcon, &QSystemTrayIcon::activated, this, &Dialog::slotActivated);

    connect(&qsc::IDeviceManage::getInstance(), &qsc::IDeviceManage::deviceConnected, this, &Dialog::onDeviceConnected);
    connect(&qsc::IDeviceManage::getInstance(), &qsc::IDeviceManage::deviceDisconnected, this, &Dialog::onDeviceDisconnected);
}

Dialog::~Dialog()
{
    qDebug() << "~Dialog()";
    updateBootConfig(false);
    qsc::IDeviceManage::getInstance().disconnectAllDevice();
    delete ui;
}

void Dialog::initUI()
{

    setAttribute(Qt::WA_DeleteOnClose);
    //setWindowFlags(windowFlags() | Qt::WindowMinimizeButtonHint | Qt::WindowCloseButtonHint | Qt::CustomizeWindowHint);

    setWindowTitle(Config::getInstance().getTitle());
#ifdef Q_OS_LINUX
    // Set window icon (inherits from application icon set in main.cpp)
    // If application icon was set, this will use it automatically
    if (!qApp->windowIcon().isNull()) {
        setWindowIcon(qApp->windowIcon());
    }
#endif

#ifdef Q_OS_WIN32
    WinUtils::setDarkBorderToWindow((HWND)this->winId(), true);
#endif

    ui->bitRateEdit->setValidator(new QIntValidator(1, 99999, this));

    ui->presetConfigBtn->setVisible(false);

    // Populate the codec-mode combo. Index 0 is the static "Default (Auto)"
    // item from the .ui; every registered encoder preset is appended below it.
    for (const EncoderPreset &preset : EncoderPresetRegistry::all()) {
        ui->codecModeBox->addItem(preset.displayName);
    }

    ui->maxSizeBox->addItem("640");
    ui->maxSizeBox->addItem("720");
    ui->maxSizeBox->addItem("1080");
    ui->maxSizeBox->addItem("1280");
    ui->maxSizeBox->addItem("1920");
    ui->maxSizeBox->addItem(tr("original"));

    ui->videoSourceBox->addItem(tr("display"));
    ui->videoSourceBox->addItem(tr("camera"));
    ui->cameraFacingBox->addItem(tr("back"));
    ui->cameraFacingBox->addItem(tr("front"));

    ui->formatBox->addItem("mp4");
    ui->formatBox->addItem("mkv");

    ui->lockOrientationBox->addItem(tr("no lock"));
    ui->lockOrientationBox->addItem("0");
    ui->lockOrientationBox->addItem("90");
    ui->lockOrientationBox->addItem("180");
    ui->lockOrientationBox->addItem("270");
    ui->lockOrientationBox->setCurrentIndex(0);

    ui->decodeModeBox->addItem(tr("FFmpeg + OpenGL (Universal Default)"));
    ui->decodeModeBox->addItem(tr("VideoToolbox + Metal (Apple Silicon Only)"));
    ui->decodeModeBox->setCurrentIndex(0);

#ifndef Q_OS_MACOS
    // 非 macOS：隐藏整个解码模式控件行
    ui->decodeModeLabel->hide();
    ui->decodeModeBox->hide();
#elif !defined(__arm64__)
    // Intel Mac：移除 VideoToolbox 选项，用户只看到 FFmpeg
    ui->decodeModeBox->removeItem(1);
#endif

    // 加载IP历史记录
    loadIpHistory();

    // 加载端口历史记录
    loadPortHistory();

    // 为deviceIpEdt添加右键菜单
    if (ui->deviceIpEdt->lineEdit()) {
        ui->deviceIpEdt->lineEdit()->setContextMenuPolicy(Qt::CustomContextMenu);
        connect(ui->deviceIpEdt->lineEdit(), &QWidget::customContextMenuRequested,
                this, &Dialog::showIpEditMenu);
    }
    
    // 为devicePortEdt添加右键菜单
    if (ui->devicePortEdt->lineEdit()) {
        ui->devicePortEdt->lineEdit()->setContextMenuPolicy(Qt::CustomContextMenu);
        connect(ui->devicePortEdt->lineEdit(), &QWidget::customContextMenuRequested,
                this, &Dialog::showPortEditMenu);
    }
    initAdvancedDisplayUi();


    auto *configTabs = new QTabWidget(ui->rightWidget);
    auto *startConfigPage = new QWidget(configTabs);
    auto *advancedDisplayPage = new QWidget(configTabs);
    auto *advancedConfigPage = new QWidget(configTabs);
    auto *startConfigLayout = new QVBoxLayout(startConfigPage);
    auto *advancedDisplayLayout = new QVBoxLayout(advancedDisplayPage);
    startConfigLayout->setContentsMargins(0, 0, 0, 0);
    advancedDisplayLayout->setContentsMargins(0, 0, 0, 0);

    // --- Limpeza: ocultar tudo que depende de ADB ---
    ui->useSingleModeCheck->setVisible(false);
    ui->simpleGroupBox->setVisible(false);
    ui->adbGroupBox->setVisible(false);
    ui->outEdit->setVisible(false);
    ui->usbGroupBox->setVisible(false);
    ui->wirelessGroupBox->setVisible(false);
    ui->videoSourceWidget->setVisible(false);
    ui->configWidget4->setVisible(false); // game scripts (ADB)

    // Remover dos layouts originais (para não ocuparem espaço)
    ui->verticalLayout_5->removeWidget(ui->adbGroupBox);
    ui->verticalLayout_5->removeWidget(ui->outEdit);
    ui->verticalLayout_6->removeWidget(ui->configGroupBox);
    ui->verticalLayout_6->removeWidget(ui->usbGroupBox);
    ui->verticalLayout_6->removeWidget(ui->wirelessGroupBox);
    ui->verticalLayout_6->removeWidget(m_advancedDisplayGroup);
    delete ui->verticalLayout_6->takeAt(0);

    // Layout limpo: esquerda = relay, direita = config
    m_relayGroup = new QGroupBox(tr("Conectar"), ui->leftWidget);
    auto *relayLayout = new QFormLayout(m_relayGroup);
    relayLayout->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
    relayLayout->setContentsMargins(8, 10, 8, 8);
    m_relayHostEdit = new QLineEdit(QStringLiteral("localhost"), m_relayGroup);
    m_relayHostEdit->setPlaceholderText(tr("Hostname do relay"));
    relayLayout->addRow(tr("Host"), m_relayHostEdit);
    m_relayCtlPortSpin = new QSpinBox(m_relayGroup);
    m_relayCtlPortSpin->setRange(1, 65535);
    m_relayCtlPortSpin->setValue(8443);
    relayLayout->addRow(tr("Porta de controle"), m_relayCtlPortSpin);
    m_relayDataPortSpin = new QSpinBox(m_relayGroup);
    m_relayDataPortSpin->setRange(1, 65535);
    m_relayDataPortSpin->setValue(9000);
    relayLayout->addRow(tr("Porta de dados"), m_relayDataPortSpin);
    m_relayDeviceIdEdit = new QLineEdit(m_relayGroup);
    m_relayDeviceIdEdit->setReadOnly(true);
    m_relayDeviceIdEdit->setPlaceholderText(tr("Selecione um dispositivo vinculado"));
    relayLayout->addRow(tr("Device ID"), m_relayDeviceIdEdit);
    m_relayTokenEdit = new QLineEdit(m_relayGroup);
    m_relayTokenEdit->setObjectName(QStringLiteral("relayTokenEdit"));
    m_relayTokenEdit->setEchoMode(QLineEdit::Password);
    m_relayTokenEdit->setPlaceholderText(tr("Token privado do controlador"));
    relayLayout->addRow(tr("Token do controlador"), m_relayTokenEdit);
    QSettings relaySettings;
    m_relayHostEdit->setText(relaySettings.value(QStringLiteral("relay/v2/host"),
                                                 QStringLiteral("localhost")).toString());
    m_relayCtlPortSpin->setValue(relaySettings.value(QStringLiteral("relay/v2/control_port"),
                                                     8443).toInt());
    m_relayDataPortSpin->setValue(relaySettings.value(QStringLiteral("relay/v2/data_port"),
                                                      9000).toInt());
    m_relayTokenEdit->setText(relaySettings.value(QStringLiteral("relay/v2/controller_token")).toString());
    connect(m_relayHostEdit, &QLineEdit::editingFinished, this, &Dialog::saveRelaySettings);
    connect(m_relayTokenEdit, &QLineEdit::editingFinished, this, &Dialog::saveRelaySettings);
    connect(m_relayCtlPortSpin, QOverload<int>::of(&QSpinBox::valueChanged),
            this, &Dialog::saveRelaySettings);
    connect(m_relayDataPortSpin, QOverload<int>::of(&QSpinBox::valueChanged),
            this, &Dialog::saveRelaySettings);
    m_relayFixedCodeLabel = new QLabel(tr("Código: ..."), m_relayGroup);
    m_relayFixedCodeLabel->setObjectName(QStringLiteral("relayFixedCodeLabel"));
    {
        QFont f = m_relayFixedCodeLabel->font();
        f.setPointSize(20);
        f.setBold(true);
        m_relayFixedCodeLabel->setFont(f);
    }
    m_relayFixedCodeLabel->setTextInteractionFlags(Qt::TextSelectableByMouse);
    m_relayFixedCodeLabel->setAlignment(Qt::AlignCenter);
    m_relayFixedCodeLabel->setStyleSheet(QStringLiteral("QLabel { color: #0066cc; background: #eef2f7; border-radius: 4px; padding: 8px; }"));
    relayLayout->addRow(m_relayFixedCodeLabel);
    auto *relayStart = new QPushButton(tr("Conectar remoto"), m_relayGroup);
    relayStart->setObjectName(QStringLiteral("relayConnectButton"));
    relayLayout->addRow(relayStart);
    connect(relayStart, &QPushButton::clicked, this, &Dialog::onRemoteConnect);
    m_devicesNam = new QNetworkAccessManager(this);

    m_devicesGroup = new QGroupBox(tr("Dispositivos"), m_relayGroup);
    m_devicesGroup->setObjectName(QStringLiteral("relayPresenceGroup"));
    m_devicesGroup->setStyleSheet(QStringLiteral(
        "QGroupBox#relayPresenceGroup { background: #151e2c; border: 1px solid #34445c;"
        "border-radius: 12px; margin-top: 13px; padding-top: 7px; color: #edf3fa;"
        "font-weight: 600; }"
        "QGroupBox#relayPresenceGroup::title { subcontrol-origin: margin; left: 13px;"
        "padding: 0 6px; }"
        "QListWidget#relayDevicesList { background: transparent; border: none;"
        "outline: 0; color: #edf3fa; }"
        "QListWidget#relayDevicesList::item { border: none; background: transparent; }"
        "QPushButton#relayDevicesRefreshButton { background: #215fa6; color: white;"
        "border: none; border-radius: 7px; padding: 8px 16px; font-weight: 600; }"
        "QPushButton#relayDevicesRefreshButton:hover { background: #2d75c2; }"
        "QPushButton#relayDevicesRefreshButton:disabled { background: #37475e;"
        "color: #a6b4c5; }"
        "QLabel#relayDevicesSummary { color: #a5b8ce; font-size: 12px;"
        "font-weight: normal; }"));

    auto *devicesLayout = new QVBoxLayout(m_devicesGroup);
    devicesLayout->setContentsMargins(10, 15, 10, 10);
    devicesLayout->setSpacing(8);
    auto *devicesHeader = new QHBoxLayout();
    m_devicesSummary = new QLabel(tr("Dispositivos vinculados"), m_devicesGroup);
    m_devicesSummary->setObjectName(QStringLiteral("relayDevicesSummary"));
    devicesHeader->addWidget(m_devicesSummary, 1);
    m_devicesRefreshBtn = new QPushButton(tr("Atualizar"), m_devicesGroup);
    m_devicesRefreshBtn->setObjectName(QStringLiteral("relayDevicesRefreshButton"));
    devicesHeader->addWidget(m_devicesRefreshBtn);
    devicesLayout->addLayout(devicesHeader);
    m_devicesList = new QListWidget(m_devicesGroup);
    m_devicesList->setObjectName(QStringLiteral("relayDevicesList"));
    m_devicesList->setItemDelegate(new DevicePresenceDelegate(m_devicesList));

    m_devicesList->setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
    m_devicesList->setUniformItemSizes(true);
    m_devicesList->setSelectionMode(QAbstractItemView::SingleSelection);
    m_devicesList->setMinimumHeight(174);
    m_devicesList->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    devicesLayout->addWidget(m_devicesList);
    relayLayout->addRow(m_devicesGroup);

    connect(m_devicesRefreshBtn, &QPushButton::clicked,
            this, &Dialog::refreshDeviceList);
    m_devicesRefreshTimer = new QTimer(this);
    m_devicesRefreshTimer->setInterval(30000);
    connect(m_devicesRefreshTimer, &QTimer::timeout, this, &Dialog::refreshDeviceList);
    m_devicesRefreshTimer->start();
    connect(m_devicesList, &QListWidget::itemDoubleClicked, this,
            [this](QListWidgetItem *item) {
        if (item && m_relayDeviceIdEdit && !item->data(Qt::UserRole).toString().isEmpty()) {
            selectRelayDevice(item->data(Qt::UserRole).toString());
        }
    });
    connect(m_devicesList, &QListWidget::itemClicked, this,
            [this](QListWidgetItem *item) {
        if (item && !item->data(Qt::UserRole).toString().isEmpty())
            selectRelayDevice(item->data(Qt::UserRole).toString());
    });
    connect(m_devicesList, &QListWidget::currentItemChanged, this,
            [this](QListWidgetItem *current, QListWidgetItem *) {
        if (current && !current->data(Qt::UserRole).toString().isEmpty())
            selectRelayDevice(current->data(Qt::UserRole).toString());
    });
    connect(m_devicesList, &QListWidget::itemSelectionChanged, this, [this]() {
        const QList<QListWidgetItem *> selected = m_devicesList->selectedItems();
        if (!selected.isEmpty()
                && !selected.first()->data(Qt::UserRole).toString().isEmpty()) {
            selectRelayDevice(selected.first()->data(Qt::UserRole).toString());
        }
    });
    const auto invalidateDevices = [this]() {
        ++m_relayDevicesGeneration;
        m_devicesList->clear();
        m_relayDeviceIdEdit->clear();
        m_devicesSummary->setText(tr("Atualize para ver dispositivos"));
        m_cachedDevices = QJsonArray();
        updateDeviceDetails();
    };
    connect(m_relayHostEdit, &QLineEdit::textChanged, this, invalidateDevices);
    connect(m_relayTokenEdit, &QLineEdit::textChanged, this, invalidateDevices);
    connect(m_relayCtlPortSpin, QOverload<int>::of(&QSpinBox::valueChanged),
            this, invalidateDevices);

    ui->verticalLayout_5->addWidget(m_relayGroup);
    startConfigLayout->addWidget(ui->configGroupBox);
    for (QWidget *fieldRow : {ui->configWidget1, ui->configWidgetCodec,
                             ui->configWidget5, ui->configWidget2}) {
        fieldRow->setMaximumHeight(54);
        fieldRow->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Fixed);
    }
    ui->configWidget3->setMaximumHeight(108);
    ui->configWidget3->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Fixed);
    ui->configGroupBox->setMaximumHeight(505);
    ui->configGroupBox->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Fixed);
    startConfigLayout->addStretch();
    advancedDisplayLayout->addWidget(m_advancedDisplayGroup);
    advancedDisplayLayout->addStretch();
    initAdvancedConfigUi(advancedConfigPage);
    configTabs->addTab(startConfigPage, tr("Start Config"));
    configTabs->addTab(advancedDisplayPage, tr("Advanced Display"));
    configTabs->addTab(advancedConfigPage, tr("Advanced Config"));
    configTabs->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Expanding);
    ui->verticalLayout_6->addWidget(configTabs);

    ui->leftWidget->setSizePolicy(QSizePolicy::Minimum, QSizePolicy::Preferred);
    ui->leftWidget->setMinimumWidth(0);
    ui->horizontalLayout_11->setStretch(0, 1);
    ui->horizontalLayout_11->setStretch(1, 2);
    ui->horizontalLayout->setStretch(0, 1);
    ui->horizontalLayout->setStretch(2, 0);

    for (QComboBox *comboBox : findChildren<QComboBox *>()) {
        comboBox->view()->setItemDelegate(new ComboBoxItemDelegate(comboBox->view()));
    }

    QSizePolicy simpleModePolicy = ui->simpleGroupBox->sizePolicy();
    simpleModePolicy.setVerticalPolicy(QSizePolicy::Expanding);
    ui->simpleGroupBox->setSizePolicy(simpleModePolicy);

    QSizePolicy logPolicy = ui->outEdit->sizePolicy();
    logPolicy.setVerticalPolicy(QSizePolicy::Expanding);
    ui->outEdit->setSizePolicy(logPolicy);
    ui->verticalLayout_5->setStretch(0, 0);
    ui->verticalLayout_5->setStretch(1, 1);
    ui->verticalLayout_5->setStretch(2, 0);
    ui->verticalLayout_5->setStretch(3, 0);
    ui->verticalLayout_4->setStretch(2, 1);
    ui->verticalLayout_6->setStretch(0, 1);

    buildPanelShell(configTabs);

    // Auto-fetch fixed code on startup
    QTimer::singleShot(500, this, &Dialog::fetchFixedCode);
}

void Dialog::buildPanelShell(QWidget *settingsTabs)
{

    ui->verticalLayout_5->removeWidget(m_relayGroup);
    ui->verticalLayout_6->removeWidget(settingsTabs);
    auto *relayForm = qobject_cast<QFormLayout *>(m_relayGroup->layout());
    if (relayForm) relayForm->removeWidget(m_devicesGroup);
    ui->leftWidget->hide();
    ui->rightWidget->hide();

    setObjectName(QStringLiteral("panelRoot"));
    setWindowTitle(tr("Painel de dispositivos — Android | QtScrcpy"));
    setMinimumSize(1060, 730);
    resize(1380, 890);
    setStyleSheet(QStringLiteral(
        "QWidget#panelRoot { background: #151d2b; color: #e4ebf6; }"
        "QWidget#panelShell { background: #171f2e; color: #e4ebf6;"
        "font-family: 'Segoe UI'; }"
        "QWidget#panelPage { background: #171f2e; }"
        "QWidget#panelShell QLabel { border: none; background: transparent; }"
        "QFrame#panelTop { background: #171f2e; border-bottom: 1px solid #2a3649; }"
        "QFrame#panelSidebar { background: #101824; border-right: 1px solid #2a3547; }"
        "QFrame#panelSurface { background: #171f2e; border: 1px solid #304056;"
        "border-radius: 12px; }"
        "QFrame#panelActivity { background: #171f2e; border-top: 1px solid #2b374a; }"
        "QLabel#panelBrand { color: #f0f4fa; font-size: 15px; font-weight: 600; }"
        "QLabel#panelMuted { color: #94a5bd; font-size: 12px; }"
        "QLabel#panelSection { color: #8498b2; font-size: 11px; font-weight: 600; }"
        "QLabel#panelPageTitle { color: #edf3fb; font-size: 20px; font-weight: 600; }"
        "QLabel#panelPageSubtitle { color: #9aabc3; font-size: 12px; }"
        "QLabel#panelMetric { color: #e9eff9; font-size: 16px; font-weight: 600; }"
        "QLabel#panelPresence { color: #9eafc7; background: #202d40;"
        "border: 1px solid #354660; border-radius: 9px; padding: 7px 12px; }"
        "QPushButton#panelNav { color: #93a4bb; background: transparent;"
        "border: none; border-radius: 8px; text-align: left; padding: 11px 13px;"
        "font-size: 13px; }"
        "QPushButton#panelNav:hover { color: #edf3fb; background: #1b293b; }"
        "QPushButton#panelNav:disabled { color: #748196; }"
        "QGroupBox#relayConnectionGroup { color: #eaf0f9; background: #1b2738;"
        "border: 1px solid #34465e; border-radius: 10px; margin-top: 16px;"
        "padding-top: 9px; font-weight: 600; }"
        "QGroupBox#relayConnectionGroup::title { subcontrol-origin: margin;"
        "left: 12px; padding: 0 7px; }"
        "QGroupBox#configGroupBox { background: #1b2738; color: #e4edf8;"
        "border: 1px solid #34465e; border-radius: 10px; margin-top: 15px;"
        "padding: 8px; }"
        "QGroupBox#configGroupBox::title { subcontrol-origin: margin;"
        "left: 12px; padding: 0 7px; }"
        "QLineEdit, QSpinBox, QComboBox { background: #111b2a; color: #e4edf8;"
        "border: 1px solid #36475c; border-radius: 6px; padding: 6px; }"
        "QLineEdit:focus, QSpinBox:focus { border: 1px solid #559be5; }"
        "QPushButton#relayConnectButton { background: #205eab; color: white;"
        "font-weight: 600; border: 0; border-radius: 8px; padding: 10px; }"
        "QPushButton#relayConnectButton:hover { background: #2d79cb; }"
        "QTextEdit#panelActivityText { background: transparent; color: #91a3bb;"
        "border: none; font-family: Consolas, monospace; font-size: 12px; }"
        "QTabWidget::pane { background: #1a2535; border: 1px solid #34465e; }"
        "QTabBar::tab { color: #a6b5c8; background: #1b2738;"
        "padding: 9px 14px; border: 1px solid #34465e; }"
        "QTabBar::tab:selected { color: #f4f8ff; background: #245eaa; }"));

    ui->horizontalLayout_11->setContentsMargins(0, 0, 0, 0);
    ui->horizontalLayout_11->setSpacing(0);
    auto *shell = new QWidget(this);
    shell->setObjectName(QStringLiteral("panelShell"));
    auto *shellLayout = new QVBoxLayout(shell);
    shellLayout->setContentsMargins(0, 0, 0, 0);
    shellLayout->setSpacing(0);
    ui->horizontalLayout_11->addWidget(shell);


    auto *top = new QFrame(shell);
    top->setObjectName(QStringLiteral("panelTop"));
    top->setFixedHeight(78);
    auto *topLayout = new QHBoxLayout(top);
    topLayout->setContentsMargins(24, 8, 23, 8);
    auto *logo = new QLabel(QStringLiteral("▣"), top);
    logo->setStyleSheet(QStringLiteral("font-size: 26px; color: #66abf2;"));
    topLayout->addWidget(logo);
    auto *brandLines = new QVBoxLayout();
    brandLines->setSpacing(2);
    auto *brand = new QLabel(tr("Painel de dispositivos — Android"), top);
    brand->setObjectName(QStringLiteral("panelBrand"));
    brandLines->addWidget(brand);
    auto *subtitle = new QLabel(tr("Console desktop  ·  QtScrcpy"), top);
    subtitle->setObjectName(QStringLiteral("panelMuted"));
    brandLines->addWidget(subtitle);
    topLayout->addLayout(brandLines);
    topLayout->addStretch(1);
    auto *timeLabel = new QLabel(top);
    timeLabel->setStyleSheet(QStringLiteral("color: #c7d5e6; font-family: Consolas;"));
    const auto setClock = [timeLabel]() {
        timeLabel->setText(QDateTime::currentDateTime().toString(QStringLiteral("HH:mm")));
    };
    setClock();
    auto *clockTimer = new QTimer(top);
    connect(clockTimer, &QTimer::timeout, this, setClock);
    clockTimer->start(30000);
    topLayout->addWidget(timeLabel);
    topLayout->addSpacing(15);
    m_headerPresence = new QLabel(tr("Aguardando atualização"), top);
    m_headerPresence->setObjectName(QStringLiteral("panelPresence"));
    m_headerPresence->setAlignment(Qt::AlignCenter);
    topLayout->addWidget(m_headerPresence);
    shellLayout->addWidget(top);


    auto *body = new QWidget(shell);
    auto *bodyLayout = new QHBoxLayout(body);
    bodyLayout->setContentsMargins(0, 0, 0, 0);
    bodyLayout->setSpacing(0);
    auto *sidebar = new QFrame(body);
    sidebar->setObjectName(QStringLiteral("panelSidebar"));
    sidebar->setFixedWidth(238);
    auto *sidebarLayout = new QVBoxLayout(sidebar);
    sidebarLayout->setContentsMargins(14, 20, 14, 17);
    sidebarLayout->setSpacing(5);
    auto *sectionsLabel = new QLabel(tr("SEÇÕES"), sidebar);
    sectionsLabel->setObjectName(QStringLiteral("panelSection"));
    sidebarLayout->addWidget(sectionsLabel);
    sidebarLayout->addSpacing(5);

    const QStringList sectionNames = {
        QStringLiteral("Dispositivos"), QStringLiteral("Estado do celular"),
        QStringLiteral("Espelho de tela"), QStringLiteral("Câmera"),
        QStringLiteral("Microfone"), QStringLiteral("Arquivos"),
        QStringLiteral("Ações remotas"), QStringLiteral("Configurações")
    };
    const QStringList sectionSymbols = {
        QStringLiteral("▣"), QStringLiteral("▥"), QStringLiteral("▧"),
        QStringLiteral("◉"), QStringLiteral("◎"), QStringLiteral("◫"),
        QStringLiteral("◇"), QStringLiteral("⚙")
    };
    for (int i = 0; i < sectionNames.size(); ++i) {
        if (i == 7) sidebarLayout->addSpacing(9);
        auto *button = new QPushButton(sectionSymbols.at(i) + QStringLiteral("    ")
                                      + sectionNames.at(i), sidebar);
        button->setObjectName(QStringLiteral("panelNav"));
        button->setFixedHeight(43);
        button->setCursor(Qt::PointingHandCursor);
        const int page = i;
        connect(button, &QPushButton::clicked, this, [this, page]() {
            showPanelPage(page);
        });
        m_navButtons.append(button);
        sidebarLayout->addWidget(button);
    }
    sidebarLayout->addStretch(1);
    auto *linkedLabel = new QLabel(tr("DISPOSITIVO VINCULADO"), sidebar);
    linkedLabel->setObjectName(QStringLiteral("panelSection"));
    sidebarLayout->addWidget(linkedLabel);
    m_sidebarDevice = new QLabel(tr("Nenhum celular selecionado\nUse “Dispositivos” para vincular"), sidebar);
    m_sidebarDevice->setObjectName(QStringLiteral("panelMuted"));
    m_sidebarDevice->setWordWrap(true);
    sidebarLayout->addWidget(m_sidebarDevice);
    bodyLayout->addWidget(sidebar);


    m_mainPages = new QStackedWidget(body);
    m_mainPages->setObjectName(QStringLiteral("panelPages"));
    bodyLayout->addWidget(m_mainPages, 1);
    shellLayout->addWidget(body, 1);

    auto *activity = new QFrame(shell);
    activity->setObjectName(QStringLiteral("panelActivity"));
    activity->setFixedHeight(168);
    auto *activityLayout = new QVBoxLayout(activity);
    activityLayout->setContentsMargins(19, 10, 19, 10);
    activityLayout->setSpacing(4);
    auto *activityTitle = new QHBoxLayout();
    auto *activityHeading = new QLabel(tr("◇  Atividade do painel"), activity);
    activityHeading->setStyleSheet(QStringLiteral("color: #dce6f5; font-weight: 600;"));
    activityTitle->addWidget(activityHeading);
    activityTitle->addStretch(1);
    auto *activityHint = new QLabel(tr("registros locais · atualizados em tempo real"), activity);
    activityHint->setObjectName(QStringLiteral("panelMuted"));
    activityTitle->addWidget(activityHint);
    activityLayout->addLayout(activityTitle);
    ui->outEdit->setObjectName(QStringLiteral("panelActivityText"));
    activityLayout->addWidget(ui->outEdit, 1);
    ui->outEdit->show();
    shellLayout->addWidget(activity);


    m_relayGroup->setObjectName(QStringLiteral("relayConnectionGroup"));
    m_relayGroup->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Expanding);
    m_relayGroup->setMinimumWidth(315);
    m_relayGroup->setMaximumWidth(410);
    m_devicesGroup->setMinimumWidth(320);
    m_devicesGroup->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);

    auto *devicesPage = new QWidget(m_mainPages);
    devicesPage->setObjectName(QStringLiteral("panelPage"));
    auto *devicesLayout = new QVBoxLayout(devicesPage);
    devicesLayout->setContentsMargins(19, 18, 19, 17);
    devicesLayout->setSpacing(12);
    auto *deviceTitle = new QLabel(tr("Dispositivos vinculados"), devicesPage);
    deviceTitle->setObjectName(QStringLiteral("panelPageTitle"));
    devicesLayout->addWidget(deviceTitle);
    auto *deviceSubtitle = new QLabel(tr("Selecione o aparelho e consulte seu estado em tempo real."), devicesPage);
    deviceSubtitle->setObjectName(QStringLiteral("panelPageSubtitle"));
    devicesLayout->addWidget(deviceSubtitle);
    auto *deviceColumns = new QHBoxLayout();
    deviceColumns->setSpacing(14);
    deviceColumns->addWidget(m_relayGroup, 2);
    deviceColumns->addWidget(m_devicesGroup, 3);
    devicesLayout->addLayout(deviceColumns, 1);
    m_mainPages->addWidget(devicesPage);


    auto *statusPage = new QWidget(m_mainPages);
    statusPage->setObjectName(QStringLiteral("panelPage"));
    auto *statusLayout = new QVBoxLayout(statusPage);
    statusLayout->setContentsMargins(14, 14, 14, 14);
    auto *statusSurface = new QFrame(statusPage);
    statusSurface->setObjectName(QStringLiteral("panelSurface"));
    auto *statusContents = new QVBoxLayout(statusSurface);
    statusContents->setContentsMargins(25, 24, 25, 24);
    m_statusEmpty = new QLabel(tr("▣  Nenhum celular selecionado\n\n"
                                 "Abra “Dispositivos” e selecione um aparelho."), statusSurface);
    m_statusEmpty->setAlignment(Qt::AlignCenter);
    m_statusEmpty->setStyleSheet(QStringLiteral("color: #c1cddd; font-size: 15px;"));
    statusContents->addWidget(m_statusEmpty, 1);
    m_statusDetails = new QFrame(statusSurface);
    auto *detailsLayout = new QVBoxLayout(m_statusDetails);
    detailsLayout->setContentsMargins(10, 10, 10, 10);
    detailsLayout->setSpacing(18);
    m_statusHeading = new QLabel(m_statusDetails);
    m_statusHeading->setObjectName(QStringLiteral("panelPageTitle"));
    detailsLayout->addWidget(m_statusHeading);
    m_statusSubheading = new QLabel(m_statusDetails);
    m_statusSubheading->setObjectName(QStringLiteral("panelPageSubtitle"));
    detailsLayout->addWidget(m_statusSubheading);
    auto *metrics = new QGridLayout();
    metrics->setSpacing(15);
    const QStringList metricNames = {QStringLiteral("BATERIA"), QStringLiteral("REDE"),
                                      QStringLiteral("TELA"), QStringLiteral("ÚLTIMO VISTO")};
    QLabel *metricValues[4] = {};
    for (int i = 0; i < 4; ++i) {
        auto *metricFrame = new QFrame(m_statusDetails);
        metricFrame->setObjectName(QStringLiteral("panelSurface"));
        metricFrame->setMinimumHeight(128);
        auto *metricLayout = new QVBoxLayout(metricFrame);
        metricLayout->setContentsMargins(17, 17, 17, 17);
        auto *metricTitle = new QLabel(metricNames.at(i), metricFrame);
        metricTitle->setObjectName(QStringLiteral("panelSection"));
        metricLayout->addWidget(metricTitle);
        metricValues[i] = new QLabel(metricFrame);
        metricValues[i]->setObjectName(QStringLiteral("panelMetric"));
        metricLayout->addWidget(metricValues[i]);
        metricLayout->addStretch();
        metrics->addWidget(metricFrame, i / 2, i % 2);
    }
    m_statusBattery = metricValues[0];
    m_statusNetwork = metricValues[1];
    m_statusScreen = metricValues[2];
    m_statusSeen = metricValues[3];
    detailsLayout->addLayout(metrics);
    detailsLayout->addStretch();
    statusContents->addWidget(m_statusDetails);
    m_statusDetails->hide();
    statusLayout->addWidget(statusSurface);
    m_mainPages->addWidget(statusPage);


    auto *screenPage = new QWidget(m_mainPages);
    screenPage->setObjectName(QStringLiteral("panelPage"));
    auto *screenLayout = new QVBoxLayout(screenPage);
    screenLayout->setContentsMargins(14, 14, 14, 14);
    auto *screenSurface = new QFrame(screenPage);
    screenSurface->setObjectName(QStringLiteral("panelSurface"));
    auto *screenContents = new QVBoxLayout(screenSurface);
    screenContents->setContentsMargins(35, 32, 35, 32);
    auto *screenTitle = new QLabel(tr("Espelho de tela"), screenSurface);
    screenTitle->setObjectName(QStringLiteral("panelPageTitle"));
    screenContents->addWidget(screenTitle);
    auto *screenDescription = new QLabel(
                tr("Selecione um dispositivo vinculado para iniciar uma sessão remota. "
                   "A autorização de captura no Android continua sendo necessária."), screenSurface);
    screenDescription->setObjectName(QStringLiteral("panelPageSubtitle"));
    screenDescription->setWordWrap(true);
    screenContents->addWidget(screenDescription);
    screenContents->addStretch();
    auto *screenAction = new QPushButton(tr("Conectar ao dispositivo selecionado"), screenSurface);
    screenAction->setObjectName(QStringLiteral("relayConnectButton"));
    screenAction->setMinimumHeight(44);
    screenAction->setMaximumWidth(360);
    connect(screenAction, &QPushButton::clicked, this, &Dialog::onRemoteConnect);
    screenContents->addWidget(screenAction, 0, Qt::AlignHCenter);
    screenContents->addStretch();
    screenLayout->addWidget(screenSurface);
    m_mainPages->addWidget(screenPage);

    const QStringList unavailable = {
        QStringLiteral("Câmera"), QStringLiteral("Microfone"),
        QStringLiteral("Arquivos"), QStringLiteral("Ações remotas")
    };
    for (const QString &name : unavailable) {
        auto *page = new QWidget(m_mainPages);
        page->setObjectName(QStringLiteral("panelPage"));
        auto *pageLayout = new QVBoxLayout(page);
        pageLayout->setContentsMargins(14, 14, 14, 14);
        auto *surface = new QFrame(page);
        surface->setObjectName(QStringLiteral("panelSurface"));
        auto *content = new QVBoxLayout(surface);
        content->setContentsMargins(25, 24, 25, 24);
        auto *caption = new QLabel(name, surface);
        caption->setObjectName(QStringLiteral("panelPageTitle"));
        content->addWidget(caption);
        auto *empty = new QLabel(tr("Esta função não está disponível nesta versão do cliente."),
                                 surface);
        empty->setAlignment(Qt::AlignCenter);
        empty->setStyleSheet(QStringLiteral("color: #a6b7cf; font-size: 14px;"));
        content->addWidget(empty, 1);
        pageLayout->addWidget(surface);
        m_mainPages->addWidget(page);
    }

    auto *settingsPage = new QWidget(m_mainPages);
    settingsPage->setObjectName(QStringLiteral("panelPage"));
    auto *settingsLayout = new QVBoxLayout(settingsPage);
    settingsLayout->setContentsMargins(18, 17, 18, 17);
    auto *settingsHeading = new QLabel(tr("Configurações do cliente"), settingsPage);
    settingsHeading->setObjectName(QStringLiteral("panelPageTitle"));
    settingsLayout->addWidget(settingsHeading);
    settingsLayout->addWidget(settingsTabs, 1);
    m_mainPages->addWidget(settingsPage);

    showPanelPage(0);

    QTimer::singleShot(850, this, &Dialog::refreshDeviceList);
}

void Dialog::showPanelPage(int index)
{
    if (!m_mainPages || index < 0 || index >= m_mainPages->count()) return;
    m_mainPages->setCurrentIndex(index);
    for (int i = 0; i < m_navButtons.size(); ++i) {
        QPushButton *button = m_navButtons.at(i);
        if (i == index) {
            button->setStyleSheet(QStringLiteral(
                "QPushButton#panelNav { background: #205b9d; color: #ffffff;"
                "border-left: 4px solid #58adff; border-radius: 8px; text-align: left;"
                "padding: 11px 9px; font-size: 13px; font-weight: 600; }"));
        } else {
            button->setStyleSheet(QString());
        }
    }
    if (index == 1) updateDeviceDetails();
}

void Dialog::selectRelayDevice(const QString &deviceId)
{
    if (deviceId.isEmpty()) return;
    m_relayDeviceIdEdit->setText(deviceId);
    updateDeviceDetails();
}

void Dialog::updateDeviceDetails()
{
    if (!m_statusDetails || !m_statusEmpty || !m_sidebarDevice) return;
    const QString selected = m_relayDeviceIdEdit->text();
    QJsonObject device;
    for (const QJsonValue &value : m_cachedDevices) {
        if (!value.isObject()) continue;
        const QJsonObject entry = value.toObject();
        if (entry.value(QStringLiteral("device_id")).toString() == selected) {
            device = entry;
            break;
        }
    }
    const bool found = !device.isEmpty();
    m_statusDetails->setVisible(found);
    m_statusEmpty->setVisible(!found);
    if (!found) {
        m_sidebarDevice->setText(tr("Nenhum celular selecionado\n"
                                   "Use “Dispositivos” para vincular"));
        return;
    }

    const QString model = device.value(QStringLiteral("model")).toString();
    const QString deviceName = model.isEmpty() ? QStringLiteral("Android") : model;
    const QString shortId = selected.left(8);
    m_sidebarDevice->setText(deviceName + QStringLiteral("\nID ") + shortId);
    m_statusHeading->setText(deviceName);
    m_statusSubheading->setText(QStringLiteral("Identificação: ") + selected);

    const int battery = device.value(QStringLiteral("battery")).toInt(-1);
    const bool charging = device.value(QStringLiteral("charging")).toBool(false);
    m_statusBattery->setText(battery < 0
                             ? QStringLiteral("Não informado")
                             : QStringLiteral("%1%  ·  %2").arg(battery)
                               .arg(charging ? QStringLiteral("Carregando")
                                             : QStringLiteral("Na bateria")));
    const QString network = device.value(QStringLiteral("network")).toString().toLower();
    QString networkName = QStringLiteral("Não informada");
    if (network == QLatin1String("wifi")) networkName = QStringLiteral("Wi-Fi");
    else if (network == QLatin1String("cellular")) networkName = QStringLiteral("Rede móvel");
    else if (network == QLatin1String("ethernet")) networkName = QStringLiteral("Ethernet");
    else if (network == QLatin1String("none")) networkName = QStringLiteral("Sem conexão");
    m_statusNetwork->setText(networkName);

    const QJsonValue screenValue = device.value(QStringLiteral("screen_on"));
    m_statusScreen->setText(!screenValue.isBool()
                            ? QStringLiteral("Não informada")
                            : (screenValue.toBool() ? QStringLiteral("Ligada")
                                                    : QStringLiteral("Desligada")));
    m_statusSeen->setText(lastSeenSummary(
                            device.value(QStringLiteral("last_seen")).toString()));
}

void Dialog::saveRelaySettings()
{
    QSettings settings;
    settings.setValue(QStringLiteral("relay/v2/host"), m_relayHostEdit->text().trimmed());
    settings.setValue(QStringLiteral("relay/v2/control_port"), m_relayCtlPortSpin->value());
    settings.setValue(QStringLiteral("relay/v2/data_port"), m_relayDataPortSpin->value());
    settings.setValue(QStringLiteral("relay/v2/controller_token"), m_relayTokenEdit->text().trimmed());
    QTimer::singleShot(300, this, &Dialog::fetchFixedCode);
}

bool Dialog::prepareRelayRequest(const QString &endpoint, QNetworkRequest &request)
{
    const QString host = m_relayHostEdit->text().trimmed();
    if (host.isEmpty() || !QSslSocket::supportsSsl()) {
        outLog(tr("O relay v2 exige host válido e suporte a TLS."));
        return false;
    }
    QUrl url;
    url.setScheme(QStringLiteral("https"));
    url.setHost(host);
    url.setPort(m_relayCtlPortSpin->value());
    url.setPath(endpoint);
    if (!url.isValid() || url.host().isEmpty()) {
        outLog(tr("Host do relay inválido."));
        return false;
    }
    request = QNetworkRequest(url);
    // Bearer credentials must never be forwarded to a redirected origin.
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::ManualRedirectPolicy);
    request.setRawHeader("Authorization", QByteArrayLiteral("Bearer ")
                         + m_relayTokenEdit->text().trimmed().toUtf8());
    QSslConfiguration config = QSslConfiguration::defaultConfiguration();
    const QString certPath = qEnvironmentVariable("QSC_RELAY_CERT").trimmed();
    if (!certPath.isEmpty()) {
        QFile certFile(certPath);
        if (!certFile.open(QIODevice::ReadOnly)) {
            outLog(tr("Certificado TLS indisponível."));
            return false;
        }
        const QList<QSslCertificate> certificates =
                QSslCertificate::fromData(certFile.readAll(), QSsl::Pem);
        if (certificates.isEmpty()) {
            outLog(tr("Certificado TLS inválido."));
            return false;
        }
        config.setCaCertificates(certificates);
    }
    config.setPeerVerifyMode(QSslSocket::VerifyPeer);
    config.setProtocol(QSsl::TlsV1_2OrLater);
    request.setSslConfiguration(config);
    return true;
}

void Dialog::fetchFixedCode()
{
    if (m_relayTokenEdit->text().trimmed().isEmpty()) {
        m_relayFixedCodeLabel->setText(tr("Configure o token"));
        return;
    }
    QNetworkRequest request;
    if (!prepareRelayRequest(QStringLiteral("/v2/fixed-code"), request)) return;
    m_relayFixedCodeLabel->setText(tr("Solicitando..."));
    request.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *reply = m_devicesNam->post(request, QByteArrayLiteral("{}"));
    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();
        if (reply->error() != QNetworkReply::NoError || status < 200 || status >= 300) {
            m_relayFixedCodeLabel->setText(tr("Falha ao obter código"));
            outLog(tr("Código fixo indisponível (HTTP %1): %2")
                   .arg(status).arg(reply->errorString()));
            return;
        }
        QJsonParseError parseError;
        const QJsonDocument response = QJsonDocument::fromJson(body, &parseError);
        const QJsonObject result = response.object();
        const QString code = result.value(QStringLiteral("code")).toString();
        static const QRegularExpression kFixedCode(QStringLiteral("^[A-Z0-9]{4,6}$"));
        if (parseError.error != QJsonParseError::NoError || !response.isObject()
                || !kFixedCode.match(code).hasMatch()) {
            m_relayFixedCodeLabel->setText(tr("Resposta inválida"));
            return;
        }
        m_relayFixedCodeLabel->setText(code);
    });
}

void Dialog::refreshDeviceList()
{
    const QString host = m_relayHostEdit->text().trimmed();
    if (host.isEmpty() || m_relayTokenEdit->text().trimmed().isEmpty()) {
        m_devicesSummary->setText(tr("Configure o acesso ao relay"));
        outLog(tr("Configure host e token antes de listar dispositivos."));
        return;
    }
    QNetworkRequest request;
    if (!prepareRelayRequest(QStringLiteral("/v1/devices"), request)) {
        m_devicesSummary->setText(tr("Falha ao preparar conexão"));
        return;
    }
    saveRelaySettings();
    ++m_relayDevicesGeneration;
    const quint64 generation = m_relayDevicesGeneration;
    m_devicesSummary->setText(tr("Consultando dispositivos…"));
    m_devicesRefreshBtn->setText(tr("Atualizando…"));
    m_devicesRefreshBtn->setEnabled(false);
    QNetworkReply *reply = m_devicesNam->get(request);
    QTimer::singleShot(15000, reply, [reply]() {
        if (reply->isRunning()) reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, generation]() {
        reply->deleteLater();
        m_devicesRefreshBtn->setEnabled(true);
        m_devicesRefreshBtn->setText(tr("Atualizar"));
        if (generation != m_relayDevicesGeneration) return;
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        if (reply->error() != QNetworkReply::NoError || status != 200) {
            m_devicesSummary->setText(tr("Não foi possível atualizar"));
            outLog(tr("Falha ao listar dispositivos (HTTP %1): %2")
                   .arg(status).arg(reply->errorString()));
            return;
        }
        const QByteArray body = reply->readAll();
        QJsonParseError error;
        const QJsonDocument document = QJsonDocument::fromJson(body, &error);
        if (error.error != QJsonParseError::NoError || !document.isArray()) {
            m_devicesSummary->setText(tr("Dados recebidos inválidos"));
            outLog(tr("Resposta inválida do relay."));
            return;
        }
        const QString previousId = m_relayDeviceIdEdit->text();
        m_devicesList->clear();
        outLog(QStringLiteral("relay_devices_body=") + QString::fromUtf8(body));
        const QJsonArray devices = document.array();
        m_cachedDevices = devices;
        int count = 0;
        int onlineCount = 0;
        QListWidgetItem *previousItem = nullptr;
        for (const QJsonValue &value : devices) {
            if (!value.isObject()) continue;
            const QJsonObject entry = value.toObject();
            const QString deviceId = entry.value(QStringLiteral("device_id")).toString();
            const QString status = entry.value(QStringLiteral("status")).toString().toLower();
            if (deviceId.isEmpty()) continue;

            const QString model = entry.value(QStringLiteral("model")).toString();
            const int batteryValue = entry.value(QStringLiteral("battery")).toInt(-1);
            const int battery = (batteryValue >= 0 && batteryValue <= 100)
                    ? batteryValue : -1;
            const bool charging = entry.value(QStringLiteral("charging")).toBool(false);
            const QString network = entry.value(QStringLiteral("network")).toString().toLower();
            const bool hasScreen = entry.value(QStringLiteral("screen_on")).isBool();
            const QString lastSeen = entry.value(QStringLiteral("last_seen")).toString();
            const QDateTime seenDate = QDateTime::fromString(lastSeen, Qt::ISODate);
            const qint64 age = seenDate.isValid()
                    ? seenDate.secsTo(QDateTime::currentDateTimeUtc()) : -1000;
            const bool freshPresence = age >= -30 && age < 90;
            const bool online = (status == QLatin1String("connected")
                                 || status == QLatin1String("waiting")
                                 || status == QLatin1String("online"))
                    && (!seenDate.isValid() || freshPresence);

            const QString shownModel = model.isEmpty() ? QStringLiteral("Android") : model;
            const QString shownStatus = online ? QStringLiteral("ONLINE")
                                               : QStringLiteral("OFFLINE");
            const QString label = QStringLiteral("%1 — ID %2 — %3 — Bateria %4 — %5 — %6 — %7")
                    .arg(shownModel)
                    .arg(deviceId.left(8))
                    .arg(shownStatus)
                    .arg(battery >= 0 ? QStringLiteral("%1%").arg(battery)
                                      : QStringLiteral("--"))
                    .arg(network.isEmpty() ? QStringLiteral("--") : network)
                    .arg(hasScreen ? (entry.value(QStringLiteral("screen_on")).toBool()
                                    ? QStringLiteral("Tela ON") : QStringLiteral("Tela OFF"))
                                   : QStringLiteral("Tela --"))
                    .arg(lastSeenSummary(lastSeen));
            auto *item = new QListWidgetItem(label, m_devicesList);
            item->setData(Qt::UserRole, deviceId);
            item->setData(DeviceModelRole, shownModel);
            item->setData(DeviceOnlineRole, online);
            item->setData(DeviceBatteryRole, battery);
            item->setData(DeviceChargingRole, charging);
            item->setData(DeviceNetworkRole, network);
            if (hasScreen) item->setData(DeviceScreenRole,
                                         entry.value(QStringLiteral("screen_on")).toBool());
            item->setData(DeviceSeenRole, lastSeenSummary(lastSeen));
            item->setToolTip(label + QStringLiteral("\n") + deviceId);
            item->setSizeHint(QSize(0, 132));
            if (deviceId == previousId) previousItem = item;
            ++count;
            if (online) ++onlineCount;
        }
        m_devicesList->sortItems();
        if (previousItem) {
            m_devicesList->setCurrentItem(previousItem);
        } else {
            m_relayDeviceIdEdit->clear();
        }
        if (!count) {
            auto *empty = new QListWidgetItem(tr("Nenhum dispositivo disponível"), m_devicesList);
            empty->setFlags(Qt::NoItemFlags);
            empty->setSizeHint(QSize(0, 100));
        }
        m_devicesSummary->setText(count == 1 ? tr("1 dispositivo vinculado")
                                             : tr("%1 dispositivos vinculados").arg(count));
        m_headerPresence->setText(onlineCount == 1 ? tr("●  1 dispositivo online")
                                     : tr("●  %1 dispositivos online").arg(onlineCount));
        m_headerPresence->setStyleSheet(QStringLiteral(
                "color: %1; background: #202d40; border: 1px solid #34475e;"
                "border-radius: 9px; padding: 7px 12px;")
                .arg(onlineCount > 0 ? QStringLiteral("#45d7a1")
                                      : QStringLiteral("#f27883")));
        updateDeviceDetails();
        qInfo() << "devices_list_loaded count=" << count;
        outLog(tr("Dispositivos listados: %1").arg(count));
    });
}

void Dialog::initAdvancedDisplayUi()
{
    m_advancedDisplayGroup = new QGroupBox(tr("Advanced display"), this);
    m_advancedDisplayGroup->setCheckable(true);
    m_advancedDisplayGroup->setChecked(false);
    auto *layout = new QFormLayout(m_advancedDisplayGroup);
    layout->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

    m_displayModeBox = new QComboBox(m_advancedDisplayGroup);
    m_displayModeBox->addItem(tr("Primary display"));
    m_displayModeBox->addItem(tr("Existing display ID"));
    m_displayModeBox->addItem(tr("New virtual display"));
    layout->addRow(tr("Display mode"), m_displayModeBox);

    m_displayIdEdit = new QLineEdit(m_advancedDisplayGroup);
    m_displayIdEdit->setPlaceholderText("1");
    layout->addRow(tr("Display ID"), m_displayIdEdit);

    m_newDisplayEdit = new QLineEdit(m_advancedDisplayGroup);
    m_newDisplayEdit->setPlaceholderText("1920x1080/240");
    layout->addRow(tr("Virtual size / DPI"), m_newDisplayEdit);

    m_cropEdit = new QLineEdit(m_advancedDisplayGroup);
    m_cropEdit->setPlaceholderText("width:height:x:y");
    layout->addRow(tr("Crop"), m_cropEdit);

    m_flexDisplayCheck = new QCheckBox(tr("Resize virtual display with window"), m_advancedDisplayGroup);
    layout->addRow(m_flexDisplayCheck);
    m_displayImePolicyBox = new QComboBox(m_advancedDisplayGroup);
    m_displayImePolicyBox->addItem(tr("Server default"), "");
    m_displayImePolicyBox->addItem("local", "local");
    m_displayImePolicyBox->addItem("fallback", "fallback");
    m_displayImePolicyBox->addItem("hide", "hide");
    layout->addRow(tr("IME policy"), m_displayImePolicyBox);
    m_vdSystemDecorationsCheck = new QCheckBox(tr("Show system decorations"), m_advancedDisplayGroup);
    m_vdSystemDecorationsCheck->setChecked(true);
    layout->addRow(m_vdSystemDecorationsCheck);
    m_vdDestroyContentCheck = new QCheckBox(tr("Destroy content on close"), m_advancedDisplayGroup);
    m_vdDestroyContentCheck->setChecked(true);
    layout->addRow(m_vdDestroyContentCheck);
    m_keepActiveCheck = new QCheckBox(tr("Keep device active"), m_advancedDisplayGroup);
    layout->addRow(m_keepActiveCheck);
    auto *startAppWidget = new QWidget(m_advancedDisplayGroup);
    auto *startAppLayout = new QHBoxLayout(startAppWidget);
    startAppLayout->setContentsMargins(0, 0, 0, 0);
    m_startAppBox = new QComboBox(startAppWidget);
    m_startAppBox->setEditable(true);
    m_startAppBox->setInsertPolicy(QComboBox::NoInsert);
    m_startAppBox->setPlaceholderText("com.android.settings");
    m_startAppBox->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    m_refreshAppsBtn = new QPushButton(tr("refresh"), startAppWidget);
    m_refreshAppsBtn->setSizePolicy(QSizePolicy::Fixed, QSizePolicy::Fixed);
    m_refreshAppsBtn->setFixedWidth(m_refreshAppsBtn->sizeHint().width());
    startAppLayout->addWidget(m_startAppBox);
    startAppLayout->addWidget(m_refreshAppsBtn);
    layout->addRow(tr("Start app"), startAppWidget);

    connect(m_displayModeBox, QOverload<int>::of(&QComboBox::currentIndexChanged), this, &Dialog::updateAdvancedDisplayUi);
    connect(m_flexDisplayCheck, &QCheckBox::toggled, this, &Dialog::updateAdvancedDisplayUi);
    connect(m_refreshAppsBtn, &QPushButton::clicked, this, &Dialog::refreshApps);
    updateAdvancedDisplayUi();
}

void Dialog::initAdvancedConfigUi(QWidget *parent)
{
    auto *pageLayout = new QVBoxLayout(parent);
    pageLayout->setContentsMargins(0, 0, 0, 0);
    auto *scrollArea = new QScrollArea(parent);
    scrollArea->setWidgetResizable(true);
    scrollArea->setFrameShape(QFrame::NoFrame);
    auto *content = new QWidget(scrollArea);
    auto *contentLayout = new QVBoxLayout(content);
    contentLayout->setContentsMargins(0, 0, 0, 0);

    auto *group = new QGroupBox(tr("Application configuration"), content);
    auto *layout = new QFormLayout(group);
    layout->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);

    m_configLanguageBox = new QComboBox(group);
    m_configLanguageBox->addItem(tr("Automatic"), "Auto");
    m_configLanguageBox->addItem("简体中文", "zh_CN");
    m_configLanguageBox->addItem("English", "en_US");
    m_configLanguageBox->addItem("日本語", "ja_JP");
    m_configLanguageBox->addItem("한국어", "ko_KR");
    layout->addRow(tr("Language"), m_configLanguageBox);

    m_configTitleEdit = new QLineEdit(group);
    layout->addRow(tr("Window title"), m_configTitleEdit);

    m_configPushPathEdit = new QLineEdit(group);
    m_configPushPathEdit->setPlaceholderText("/sdcard/");
    layout->addRow(tr("Push file path"), m_configPushPathEdit);

    m_configMaxFpsSpin = new QSpinBox(group);
    m_configMaxFpsSpin->setRange(0, 1000);
    m_configMaxFpsSpin->setSpecialValueText(tr("Unlimited"));
    layout->addRow(tr("Maximum FPS"), m_configMaxFpsSpin);

    m_configRenderExpiredCheck = new QCheckBox(tr("Render expired video frames"), group);
    layout->addRow(m_configRenderExpiredCheck);

    m_configOpenGlBox = new QComboBox(group);
    m_configOpenGlBox->addItem(tr("Automatic"), -1);
    m_configOpenGlBox->addItem(tr("Software OpenGL"), 0);
    m_configOpenGlBox->addItem(tr("OpenGL ES"), 1);
    m_configOpenGlBox->addItem(tr("Desktop OpenGL"), 2);
    m_configOpenGlBox->setToolTip(tr("Takes effect after restarting QtScrcpy."));
    layout->addRow(tr("OpenGL backend"), m_configOpenGlBox);

    m_configServerPathEdit = new QLineEdit(group);
    m_configServerPathEdit->setPlaceholderText("/data/local/tmp/scrcpy-server.jar");
    layout->addRow(tr("Device server path"), m_configServerPathEdit);

    m_configAdbPathEdit = new QLineEdit(group);
    m_configAdbPathEdit->setPlaceholderText(tr("Use bundled ADB"));
    layout->addRow(tr("ADB executable"), m_configAdbPathEdit);

    m_configCodecOptionsEdit = new QLineEdit(group);
    m_configCodecOptionsEdit->setPlaceholderText("profile=1,level=2");
    layout->addRow(tr("Codec options"), m_configCodecOptionsEdit);

    m_configCodecNameEdit = new QLineEdit(group);
    m_configCodecNameEdit->setPlaceholderText("OMX.qcom.video.encoder.avc");
    layout->addRow(tr("Codec name"), m_configCodecNameEdit);

    m_configLogLevelBox = new QComboBox(group);
    m_configLogLevelBox->addItem("verbose", "verbose");
    m_configLogLevelBox->addItem("debug", "debug");
    m_configLogLevelBox->addItem("info", "info");
    m_configLogLevelBox->addItem("warn", "warn");
    m_configLogLevelBox->addItem("error", "error");
    layout->addRow(tr("Log level"), m_configLogLevelBox);

    auto *buttons = new QHBoxLayout();
    auto *openConfigButton = new QPushButton(tr("Open Config Directory"), group);
    auto *openKeymapButton = new QPushButton(tr("Open Keymap Directory"), group);
    auto *saveButton = new QPushButton(tr("Save"), group);
    buttons->addWidget(openConfigButton);
    buttons->addWidget(openKeymapButton);
    buttons->addStretch();
    buttons->addWidget(saveButton);
    layout->addRow(buttons);

    contentLayout->addWidget(group);
    contentLayout->addStretch();
    scrollArea->setWidget(content);
    pageLayout->addWidget(scrollArea);

    connect(openConfigButton, &QPushButton::clicked, this, [this] {
        openUserDirectory(Config::getInstance().getConfigDirectory());
    });
    connect(openKeymapButton, &QPushButton::clicked, this, [this] {
        openUserDirectory(getKeyMapPath());
    });
    connect(saveButton, &QPushButton::clicked, this, &Dialog::saveAdvancedConfig);
    loadAdvancedConfig();
}

void Dialog::loadAdvancedConfig()
{
    Config &config = Config::getInstance();
    m_configLanguageBox->setCurrentIndex(qMax(0, m_configLanguageBox->findData(config.getLanguage())));
    m_configTitleEdit->setText(config.getTitle());
    m_configPushPathEdit->setText(config.getPushFilePath());
    m_configMaxFpsSpin->setValue(qBound(0, config.getMaxFps(), m_configMaxFpsSpin->maximum()));
    m_configRenderExpiredCheck->setChecked(config.getRenderExpiredFrames() != 0);
    m_configOpenGlBox->setCurrentIndex(qMax(0, m_configOpenGlBox->findData(config.getDesktopOpenGL())));
    m_configServerPathEdit->setText(config.getServerPath());
    m_configAdbPathEdit->setText(config.getAdbPath());
    m_configCodecOptionsEdit->setText(config.getCodecOptions());
    m_configCodecNameEdit->setText(config.getCodecName());
    m_configLogLevelBox->setCurrentIndex(qMax(0, m_configLogLevelBox->findData(config.getLogLevel())));
}

void Dialog::saveAdvancedConfig()
{
    QString pushPath = m_configPushPathEdit->text().trimmed();
    if (!pushPath.isEmpty() && !pushPath.endsWith('/')) {
        pushPath += '/';
    }

    QMap<QString, QVariant> values;
    values.insert("Language", m_configLanguageBox->currentData());
    values.insert("WindowTitle", m_configTitleEdit->text().trimmed());
    values.insert("PushFilePath", pushPath);
    values.insert("MaxFps", m_configMaxFpsSpin->value());
    values.insert("RenderExpiredFrames", m_configRenderExpiredCheck->isChecked() ? 1 : 0);
    values.insert("UseDesktopOpenGL", m_configOpenGlBox->currentData());
    values.insert("ServerPath", m_configServerPathEdit->text().trimmed());
    values.insert("AdbPath", m_configAdbPathEdit->text().trimmed());
    values.insert("CodecOptions", m_configCodecOptionsEdit->text().trimmed());
    values.insert("CodecName", m_configCodecNameEdit->text().trimmed());
    values.insert("LogLevel", m_configLogLevelBox->currentData());

    if (!Config::getInstance().updateCommonConfig(values)) {
        QMessageBox::warning(this, tr("Save failed"), tr("Unable to save config.ini."));
        return;
    }
    m_configPushPathEdit->setText(pushPath);
    QMessageBox::information(this, tr("Configuration saved"),
                             tr("The settings were saved to config.ini. Restart QtScrcpy for all changes to take effect."));
}

void Dialog::openUserDirectory(const QString &path)
{
    if (!QDir().mkpath(path) || !QDesktopServices::openUrl(QUrl::fromLocalFile(path))) {
        QMessageBox::warning(this, tr("Open directory failed"), path);
    }
}

void Dialog::updateAdvancedDisplayUi()
{
    if (!m_displayModeBox) {
        return;
    }
    const bool existing = m_displayModeBox->currentIndex() == 1;
    const bool virtualDisplay = m_displayModeBox->currentIndex() == 2;
    m_displayIdEdit->setEnabled(existing);
    m_newDisplayEdit->setEnabled(virtualDisplay);
    m_flexDisplayCheck->setEnabled(virtualDisplay);
    if (!virtualDisplay) {
        m_flexDisplayCheck->setChecked(false);
    }
    m_displayImePolicyBox->setEnabled(virtualDisplay);
    m_vdSystemDecorationsCheck->setEnabled(virtualDisplay);
    m_vdDestroyContentCheck->setEnabled(virtualDisplay);
    m_cropEdit->setEnabled(!m_flexDisplayCheck->isChecked());
}

void Dialog::updateBootConfig(bool toView)
{
    if (toView) {
        UserBootConfig config = Config::getInstance().getUserBootConfig();

        if (config.bitRate == 0) {
            ui->bitRateBox->setCurrentText("Mbps");
        } else if (config.bitRate % 1000000 == 0) {
            ui->bitRateEdit->setText(QString::number(config.bitRate / 1000000));
            ui->bitRateBox->setCurrentText("Mbps");
        } else {
            ui->bitRateEdit->setText(QString::number(config.bitRate / 1000));
            ui->bitRateBox->setCurrentText("Kbps");
        }

        ui->maxSizeBox->setCurrentIndex(config.maxSizeIndex);
        ui->formatBox->setCurrentIndex(config.recordFormatIndex);
        ui->recordPathEdt->setText(config.recordPath);
        ui->lockOrientationBox->setCurrentIndex(config.lockOrientationIndex);
        ui->framelessCheck->setChecked(config.framelessWindow);
        ui->recordScreenCheck->setChecked(config.recordScreen);
        ui->notDisplayCheck->setChecked(config.recordBackground);
        ui->useReverseCheck->setChecked(config.reverseConnect);
        ui->fpsCheck->setChecked(config.showFPS);
        ui->alwaysTopCheck->setChecked(config.windowOnTop);
        ui->closeScreenCheck->setChecked(config.autoOffScreen);
        ui->stayAwakeCheck->setChecked(config.keepAlive);
        ui->useSingleModeCheck->setChecked(config.simpleMode);
        ui->autoUpdatecheckBox->setChecked(config.autoUpdateDevice);
        ui->showToolbar->setChecked(config.showToolbar);
        ui->quitOnCloseCheck->setChecked(config.quitOnClose);
        ui->decodeModeBox->setCurrentIndex(config.decodeMode);
        ui->codecModeBox->setCurrentIndex(config.codecModeIndex);

        // Restore encoder preset dialog state (if dialog was previously opened)
        if (m_presetDialog) {
            m_presetDialog->setLevel(config.presetLevel);
        }
        ui->videoSourceBox->setCurrentIndex(config.videoSource);
        ui->cameraFacingBox->setCurrentIndex(qBound(0, config.cameraFacing, 1));
        if (m_advancedDisplayGroup) {
            m_advancedDisplayGroup->setChecked(config.advancedDisplay);
            m_displayModeBox->setCurrentIndex(qBound(0, config.displayMode, 2));
            m_displayIdEdit->setText(config.displayId);
            m_newDisplayEdit->setText(config.newDisplay);
            m_cropEdit->setText(config.crop);
            m_flexDisplayCheck->setChecked(config.flexDisplay);
            m_displayImePolicyBox->setCurrentIndex(qMax(0, m_displayImePolicyBox->findData(config.displayImePolicy)));
            m_vdSystemDecorationsCheck->setChecked(config.vdSystemDecorations);
            m_vdDestroyContentCheck->setChecked(config.vdDestroyContent);
            m_keepActiveCheck->setChecked(config.keepActive);
            m_startAppBox->setEditText(config.startApp);
            updateAdvancedDisplayUi();
        }
        updateVideoSourceUi();
    } else {
        UserBootConfig config = Config::getInstance().getUserBootConfig();

        config.bitRate = getBitRate();
        config.maxSizeIndex = ui->maxSizeBox->currentIndex();
        config.recordFormatIndex = ui->formatBox->currentIndex();
        config.recordPath = ui->recordPathEdt->text();
        config.lockOrientationIndex = ui->lockOrientationBox->currentIndex();
        config.recordScreen = ui->recordScreenCheck->isChecked();
        config.recordBackground = ui->notDisplayCheck->isChecked();
        config.reverseConnect = ui->useReverseCheck->isChecked();
        config.showFPS = ui->fpsCheck->isChecked();
        config.windowOnTop = ui->alwaysTopCheck->isChecked();
        config.autoOffScreen = ui->closeScreenCheck->isChecked();
        config.framelessWindow = ui->framelessCheck->isChecked();
        config.keepAlive = ui->stayAwakeCheck->isChecked();
        config.simpleMode = ui->useSingleModeCheck->isChecked();
        config.autoUpdateDevice = ui->autoUpdatecheckBox->isChecked();
        config.showToolbar = ui->showToolbar->isChecked();
        config.quitOnClose = ui->quitOnCloseCheck->isChecked();
        config.decodeMode = ui->decodeModeBox->currentIndex();
        config.codecModeIndex = ui->codecModeBox->currentIndex();

        // Save encoder preset dialog state (if opened)
        if (m_presetDialog) {
            config.presetLevel = m_presetDialog->selectedLevel();
        }

        config.videoSource = ui->videoSourceBox->currentIndex();
        config.cameraFacing = qMin(ui->cameraFacingBox->currentIndex(), 1);
        if (m_advancedDisplayGroup) {
            config.advancedDisplay = m_advancedDisplayGroup->isChecked();
            config.displayMode = m_displayModeBox->currentIndex();
            config.displayId = m_displayIdEdit->text().trimmed();
            config.newDisplay = m_newDisplayEdit->text().trimmed();
            config.crop = m_cropEdit->text().trimmed();
            config.flexDisplay = m_flexDisplayCheck->isChecked();
            config.displayImePolicy = m_displayImePolicyBox->currentData().toString();
            config.vdSystemDecorations = m_vdSystemDecorationsCheck->isChecked();
            config.vdDestroyContent = m_vdDestroyContentCheck->isChecked();
            config.keepActive = m_keepActiveCheck->isChecked();
            config.startApp = m_startAppBox->currentData().toString();
            if (config.startApp.isEmpty()) {
                config.startApp = m_startAppBox->currentText().trimmed();
            }
        }

        // 保存当前IP到历史记录
        QString currentIp = ui->deviceIpEdt->currentText().trimmed();
        if (!currentIp.isEmpty()) {
            saveIpHistory(currentIp);
        }

        Config::getInstance().setUserBootConfig(config);
    }
}

void Dialog::execAdbCmd()
{
    if (checkAdbRun()) {
        return;
    }
    QString cmd = ui->adbCommandEdt->text().trimmed();
    outLog("adb " + cmd, false);
#if QT_VERSION >= QT_VERSION_CHECK(5, 15, 0)
    m_adb.execute(ui->serialBox->currentText().trimmed(), cmd.split(" ", Qt::SkipEmptyParts));
#else
    m_adb.execute(ui->serialBox->currentText().trimmed(), cmd.split(" ", QString::SkipEmptyParts));
#endif
}

void Dialog::delayMs(int ms)
{
    QTime dieTime = QTime::currentTime().addMSecs(ms);

    while (QTime::currentTime() < dieTime) {
        QCoreApplication::processEvents(QEventLoop::AllEvents, 100);
    }
}

QString Dialog::getGameScript(const QString &fileName)
{
    if (fileName.isEmpty()) {
        return "";
    }

    QFile loadFile(getKeyMapPath() + "/" + fileName);
    if (!loadFile.exists()) {
        loadFile.setFileName(getDefaultKeyMapPath() + "/" + fileName);
    }
    if (!loadFile.open(QIODevice::ReadOnly)) {
        outLog("open file failed:" + fileName, true);
        return "";
    }

    QString ret = loadFile.readAll();
    loadFile.close();
    return ret;
}

void Dialog::slotActivated(QSystemTrayIcon::ActivationReason reason)
{
    switch (reason) {
    case QSystemTrayIcon::Trigger:
#ifdef Q_OS_WIN32
        this->show();
#endif
        break;
    default:
        break;
    }
}

void Dialog::bringToFront()
{
    show();
    setWindowState((windowState() & ~Qt::WindowMinimized) | Qt::WindowActive);
    raise();
    activateWindow();
}

void Dialog::closeEvent(QCloseEvent *event)
{
    if (ui->quitOnCloseCheck->isChecked()) {
        // The user opted out of the system tray: closing the window quits the app.
        // Ignore the event (instead of accepting it) so WA_DeleteOnClose does not
        // delete this dialog here; main() deletes it after the event loop returns.
        m_hideIcon->hide();
        event->ignore();
        qApp->quit();
        return;
    }

    this->hide();
    if (!Config::getInstance().getTrayMessageShown()) {
        Config::getInstance().setTrayMessageShown(true);
        m_hideIcon->showMessage(tr("Notice"),
                                tr("Hidden here!"),
                                QSystemTrayIcon::Information,
                                3000);
    }
    event->ignore();
}

void Dialog::on_updateDevice_clicked()
{
    if (checkAdbRun()) {
        return;
    }
    outLog("update devices...", false);
    m_adb.execute("", QStringList() << "devices");
}

void Dialog::updateVideoSourceUi()
{
    const bool camera = ui->videoSourceBox->currentIndex() == qsc::VIDEO_SOURCE_CAMERA;
    ui->cameraFacingLabel->setEnabled(camera);
    ui->cameraFacingBox->setEnabled(camera);
    ui->refreshCameraBtn->setEnabled(camera);
    ui->closeScreenCheck->setEnabled(!camera);
    ui->stayAwakeCheck->setEnabled(!camera);
    ui->gameBox->setEnabled(!camera);
    ui->refreshGameScriptBtn->setEnabled(!camera);
    ui->applyScriptBtn->setEnabled(!camera);
    ui->installSndcpyBtn->setEnabled(!camera);
    ui->startAudioBtn->setEnabled(!camera);
    if (m_advancedDisplayGroup) {
        m_advancedDisplayGroup->setEnabled(!camera);
    }
}

void Dialog::on_videoSourceBox_currentIndexChanged(int)
{
    updateVideoSourceUi();
}

void Dialog::on_startServerBtn_clicked()
{
    outLog("start server...", false);

    // this is ok that "original" toUshort is 0
    quint16 videoSize = ui->maxSizeBox->currentText().trimmed().toUShort();
    qsc::DeviceParams params;
    params.serial = ui->serialBox->currentText().trimmed();
    params.maxSize = videoSize;
    params.bitRate = getBitRate();
    // on devices with Android >= 10, the capture frame rate can be limited
    params.maxFps = static_cast<quint32>(Config::getInstance().getMaxFps());
    params.videoSource = static_cast<qsc::VideoSource>(ui->videoSourceBox->currentIndex());
    params.cameraFacing = ui->cameraFacingBox->currentIndex() == 1
            ? qsc::CAMERA_FACING_FRONT
            : qsc::CAMERA_FACING_BACK;
    params.cameraId = ui->cameraFacingBox->currentData().toString();
    const bool camera = params.videoSource == qsc::VIDEO_SOURCE_CAMERA;
    params.closeScreen = !camera && ui->closeScreenCheck->isChecked();
    params.useReverse = ui->useReverseCheck->isChecked();
    params.display = !ui->notDisplayCheck->isChecked();
    params.renderExpiredFrames = Config::getInstance().getRenderExpiredFrames();
    if (ui->lockOrientationBox->currentIndex() > 0) {
        params.captureOrientationLock = 1;
        params.captureOrientation = (ui->lockOrientationBox->currentIndex() - 1) * 90;
    }
    // Camera sensors expose their video stream in landscape by default. Rotate
    // the default camera preview to portrait, while preserving an explicit
    // orientation selected by the user.
    if (camera && params.captureOrientationLock == 0) {
        params.captureOrientation = 90;
    }
    params.stayAwake = !camera && ui->stayAwakeCheck->isChecked();
    params.recordFile = ui->recordScreenCheck->isChecked();
    params.recordPath = ui->recordPathEdt->text().trimmed();
    params.recordFileFormat = ui->formatBox->currentText().trimmed();
    params.serverLocalPath = getServerPath();
    params.serverRemotePath = Config::getInstance().getServerPath();
    params.pushFilePath = Config::getInstance().getPushFilePath();
    params.gameScript = camera ? QString() : getGameScript(ui->gameBox->currentText());
    params.logLevel = Config::getInstance().getLogLevel();
    // Apply an encoder preset (when a preset mode is selected) or the ini default.
    const int codecModeIndex = ui->codecModeBox->currentIndex();
    if (codecModeIndex > 0) {
        const EncoderPreset &preset = EncoderPresetRegistry::all().at(codecModeIndex - 1);
        // Restore from the open dialog's selection, or fall back to the saved tier.
        int level = 1;
        if (m_presetDialog) {
            level = m_presetDialog->selectedLevel();
        } else {
            level = Config::getInstance().getUserBootConfig().presetLevel;
        }
        QString codecOptions;
        quint32 bitRate = 0;
        preset.buildParams(level, codecOptions, bitRate);
        params.codecOptions = codecOptions;
        if (!preset.codecName.isEmpty()) {
            params.codecName = preset.codecName;
        }
        if (bitRate > 0) {
            params.bitRate = bitRate;
        }
    } else {
        params.codecOptions = Config::getInstance().getCodecOptions();
        params.codecName = Config::getInstance().getCodecName();
    }
    params.scid = QRandomGenerator::global()->bounded(1, 10000) & 0x7FFFFFFF;
    params.decodeMode = ui->decodeModeBox->currentIndex();
    // Disabled widgets may remain checked from persisted settings. Advanced
    // display options are not valid for camera capture, so never copy them
    // into camera session parameters.
    if (!camera && m_advancedDisplayGroup && m_advancedDisplayGroup->isChecked()) {
        const int displayMode = m_displayModeBox->currentIndex();
        if (displayMode == 1) {
            bool ok = false;
            const int displayId = m_displayIdEdit->text().trimmed().toInt(&ok);
            if (!ok || displayId < 0) {
                outLog(tr("invalid display ID"));
                return;
            }
            params.displayId = displayId;
        } else if (displayMode == 2) {
            params.newDisplay = m_newDisplayEdit->text().trimmed();
            if (params.newDisplay.isEmpty()) {
                // Match scrcpy's flex default (1280x960 at 160 dpi) while
                // keeping the command-line parameter explicit.
                params.newDisplay = "1280x960/160";
            }
            params.flexDisplay = m_flexDisplayCheck->isChecked();
            params.vdSystemDecorations = m_vdSystemDecorationsCheck->isChecked();
            params.vdDestroyContent = m_vdDestroyContentCheck->isChecked();
            params.displayImePolicy = m_displayImePolicyBox->currentData().toString();
        }
        params.keepActive = m_keepActiveCheck->isChecked();
        params.startApp = m_startAppBox->currentData().toString();
        if (params.startApp.isEmpty()) {
            params.startApp = m_startAppBox->currentText().trimmed();
        }
        // scrcpy forbids crop with flex display. Preserve the entered value
        // for a later non-flex session, but never pass it to the server.
        params.crop = params.flexDisplay ? QString() : m_cropEdit->text().trimmed();
    }
    if (params.flexDisplay && (params.newDisplay.isEmpty() || !params.display || !params.crop.isEmpty())) {
        outLog(tr("flex display requires video, a new virtual display, and no crop"));
        return;
    }

    const bool needsVirtualDisplayCheck = !params.newDisplay.isEmpty();
    if (!camera && !needsVirtualDisplayCheck) {
        qsc::IDeviceManage::getInstance().connectDevice(params);
        return;
    }

    auto *versionAdb = new qsc::AdbProcess(this);
    connect(versionAdb, &qsc::AdbProcess::adbProcessResult, this,
            [this, versionAdb, camera, params](qsc::AdbProcess::ADB_EXEC_RESULT result) {
        if (result == qsc::AdbProcess::AER_SUCCESS_EXEC) {
            bool ok = false;
            const int sdk = versionAdb->getStdOut().trimmed().toInt(&ok);
            const int minimumSdk = camera ? 31 : 29;
            if (ok && sdk >= minimumSdk) {
                qsc::IDeviceManage::getInstance().connectDevice(params);
            } else {
                outLog(camera ? tr("camera preview requires Android 12 or later")
                              : tr("virtual display requires Android 10 or later"));
            }
            versionAdb->deleteLater();
        } else if (result == qsc::AdbProcess::AER_ERROR_EXEC
                   || result == qsc::AdbProcess::AER_ERROR_START
                   || result == qsc::AdbProcess::AER_ERROR_MISSING_BINARY) {
            outLog(tr("could not verify Android version for camera preview"));
            versionAdb->deleteLater();
        }
    });
    versionAdb->execute(params.serial, QStringList() << "shell" << "getprop" << "ro.build.version.sdk");
}

void Dialog::onRemoteConnect()
{
    const QString host = m_relayHostEdit->text().trimmed();
    const QString deviceId = m_relayDeviceIdEdit->text().trimmed();
    static const QRegularExpression kDeviceId(QStringLiteral("^[A-Za-z0-9_.-]+$"));
    if (host.isEmpty() || !kDeviceId.match(deviceId).hasMatch()
            || m_relayTokenEdit->text().isEmpty()) {
        outLog(tr("Remote connection requires a host, a valid device ID and a token"));
        return;
    }

    qsc::DeviceParams params;
    params.transport = qsc::TRANSPORT_RELAY;
    params.serial = QStringLiteral("relay/") + deviceId;
    params.relayHost = host;
    params.relayCtlPort = static_cast<quint16>(m_relayCtlPortSpin->value());
    params.relayDataPort = static_cast<quint16>(m_relayDataPortSpin->value());
    params.relayDeviceId = deviceId;
    params.relayToken = m_relayTokenEdit->text();
    params.display = true;
    params.decodeMode = ui->decodeModeBox->currentIndex();
    params.renderExpiredFrames = Config::getInstance().getRenderExpiredFrames();

    // The remote path does not touch AdbProcess or the USB/device discovery UI.
    auto &devices = qsc::IDeviceManage::getInstance();
    if (devices.getDevice(params.serial)) {
        const QString message = tr("Remote device %1 is already connected.").arg(params.serial);
        outLog(message);
        qInfo().noquote() << message;
    } else if (!devices.connectDevice(params)) {
        const QString message = tr("Remote connection could not start for %1.").arg(params.serial);
        outLog(message);
        qWarning().noquote() << message;
    } else {
        outLog(tr("Connecting remotely to %1 via %2:%3")
               .arg(deviceId, host).arg(params.relayCtlPort));
    }
}

void Dialog::on_refreshCameraBtn_clicked()
{
    const QString serial = ui->serialBox->currentText().trimmed();
    if (serial.isEmpty()) {
        outLog(tr("no device"));
        return;
    }
    if (qsc::IDeviceManage::getInstance().getDevice(serial)) {
        outLog(tr("stop preview first"));
        return;
    }

    ui->refreshCameraBtn->setEnabled(false);
    ui->refreshCameraBtn->setText("...");

    auto *pushAdb = new qsc::AdbProcess(this);
    connect(pushAdb, &qsc::AdbProcess::adbProcessResult, this,
            [this, pushAdb, serial](qsc::AdbProcess::ADB_EXEC_RESULT result) {
        if (result == qsc::AdbProcess::AER_SUCCESS_EXEC) {
            pushAdb->deleteLater();

            auto *listAdb = new qsc::AdbProcess(this);
            connect(listAdb, &qsc::AdbProcess::adbProcessResult, this,
                    [this, listAdb](qsc::AdbProcess::ADB_EXEC_RESULT listResult) {
                if (listResult == qsc::AdbProcess::AER_SUCCESS_START) {
                    return;
                }
                ui->refreshCameraBtn->setText(tr("refresh"));
                ui->refreshCameraBtn->setEnabled(ui->videoSourceBox->currentIndex() == qsc::VIDEO_SOURCE_CAMERA);

                if (listResult != qsc::AdbProcess::AER_SUCCESS_EXEC) {
                    outLog(tr("camera refresh failed"));
                    listAdb->deleteLater();
                    return;
                }

                const QString output = listAdb->getStdOut() + '\n' + listAdb->getErrorOut();
                const QRegularExpression pattern(R"(--camera-id=(\S+)\s+\(([^,\)]+))");
                QRegularExpressionMatchIterator matches = pattern.globalMatch(output);

                const int facingIndex = ui->cameraFacingBox->currentIndex();
                ui->cameraFacingBox->clear();
                ui->cameraFacingBox->addItem(tr("back"));
                ui->cameraFacingBox->addItem(tr("front"));

                int cameraCount = 0;
                while (matches.hasNext()) {
                    const QRegularExpressionMatch match = matches.next();
                    const QString cameraId = match.captured(1);
                    const QString facing = match.captured(2).trimmed();
                    ui->cameraFacingBox->addItem(QString("%1 (%2)").arg(cameraId, facing), cameraId);
                    ++cameraCount;
                }

                ui->cameraFacingBox->setCurrentIndex(qMin(facingIndex, ui->cameraFacingBox->count() - 1));
                outLog(cameraCount ? tr("camera refreshed") : tr("no camera"));
                listAdb->deleteLater();
            });

            QStringList args;
            args << "shell";
            args << QString("CLASSPATH=%1").arg(Config::getInstance().getServerPath());
            args << "app_process" << "/" << "com.genymobile.scrcpy.Server" << "4.1";
            args << "list_cameras=true" << "log_level=info";
            listAdb->execute(serial, args);
        } else if (result == qsc::AdbProcess::AER_ERROR_EXEC
                   || result == qsc::AdbProcess::AER_ERROR_START
                   || result == qsc::AdbProcess::AER_ERROR_MISSING_BINARY) {
            ui->refreshCameraBtn->setText(tr("refresh"));
            ui->refreshCameraBtn->setEnabled(ui->videoSourceBox->currentIndex() == qsc::VIDEO_SOURCE_CAMERA);
            outLog(tr("camera refresh failed"));
            pushAdb->deleteLater();
        }
    });
    pushAdb->push(serial, getServerPath(), Config::getInstance().getServerPath());
}

void Dialog::refreshApps()
{
    const QString serial = ui->serialBox->currentText().trimmed();
    if (serial.isEmpty()) {
        outLog(tr("no device"));
        return;
    }
    if (qsc::IDeviceManage::getInstance().getDevice(serial)) {
        outLog(tr("stop server first"));
        return;
    }

    m_refreshAppsBtn->setEnabled(false);
    m_refreshAppsBtn->setText("...");

    auto restoreRefreshButton = [this]() {
        m_refreshAppsBtn->setText(tr("refresh"));
        m_refreshAppsBtn->setEnabled(ui->videoSourceBox->currentIndex() == qsc::VIDEO_SOURCE_DISPLAY);
    };

    auto *pushAdb = new qsc::AdbProcess(this);
    connect(pushAdb, &qsc::AdbProcess::adbProcessResult, this,
            [this, pushAdb, serial, restoreRefreshButton](qsc::AdbProcess::ADB_EXEC_RESULT result) {
        if (result == qsc::AdbProcess::AER_SUCCESS_EXEC) {
            pushAdb->deleteLater();

            auto *listAdb = new qsc::AdbProcess(this);
            connect(listAdb, &qsc::AdbProcess::adbProcessResult, this,
                    [this, listAdb, restoreRefreshButton](qsc::AdbProcess::ADB_EXEC_RESULT listResult) {
                if (listResult == qsc::AdbProcess::AER_SUCCESS_START) {
                    return;
                }
                restoreRefreshButton();

                if (listResult != qsc::AdbProcess::AER_SUCCESS_EXEC) {
                    outLog(tr("app refresh failed"));
                    listAdb->deleteLater();
                    return;
                }

                const QString selected = m_startAppBox->currentData().toString().isEmpty()
                        ? m_startAppBox->currentText().trimmed()
                        : m_startAppBox->currentData().toString();
                const QString output = listAdb->getStdOut() + '\n' + listAdb->getErrorOut();
                const QRegularExpression pattern(
                        R"(^\s*[\*\-]\s+(.+?)\s+([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)\s*$)",
                        QRegularExpression::MultilineOption);
                QRegularExpressionMatchIterator matches = pattern.globalMatch(output);

                m_startAppBox->clear();
                m_startAppBox->addItem(QString(), QString());
                int appCount = 0;
                while (matches.hasNext()) {
                    const QRegularExpressionMatch match = matches.next();
                    const QString name = match.captured(1).trimmed();
                    const QString packageName = match.captured(2);
                    m_startAppBox->addItem(QString("%1 (%2)").arg(name, packageName), packageName);
                    ++appCount;
                }

                const int selectedIndex = m_startAppBox->findData(selected);
                if (selectedIndex >= 0) {
                    m_startAppBox->setCurrentIndex(selectedIndex);
                } else {
                    m_startAppBox->setEditText(selected);
                }
                outLog(appCount ? tr("apps refreshed") : tr("no launchable app"));
                listAdb->deleteLater();
            });

            QStringList args;
            args << "shell";
            args << QString("CLASSPATH=%1").arg(Config::getInstance().getServerPath());
            args << "app_process" << "/" << "com.genymobile.scrcpy.Server" << "4.1";
            args << "list_apps=true" << "log_level=info";
            listAdb->execute(serial, args);
        } else if (result == qsc::AdbProcess::AER_ERROR_EXEC
                   || result == qsc::AdbProcess::AER_ERROR_START
                   || result == qsc::AdbProcess::AER_ERROR_MISSING_BINARY) {
            restoreRefreshButton();
            outLog(tr("app refresh failed"));
            pushAdb->deleteLater();
        }
    });
    pushAdb->push(serial, getServerPath(), Config::getInstance().getServerPath());
}

void Dialog::on_stopServerBtn_clicked()
{
    if (qsc::IDeviceManage::getInstance().disconnectDevice(ui->serialBox->currentText().trimmed())) {
        outLog("stop server");
    }
}

void Dialog::on_wirelessConnectBtn_clicked()
{
    if (checkAdbRun()) {
        return;
    }
    QString addr = ui->deviceIpEdt->currentText().trimmed();
    if (addr.isEmpty()) {
        outLog("error: device ip is null", false);
        return;
    }

    if (!ui->devicePortEdt->currentText().isEmpty()) {
        addr += ":";
        addr += ui->devicePortEdt->currentText().trimmed();
    } else if (!ui->devicePortEdt->lineEdit()->placeholderText().isEmpty()) {
        addr += ":";
        addr += ui->devicePortEdt->lineEdit()->placeholderText().trimmed();
    } else {
        outLog("error: device port is null", false);
        return;
    }

    // 保存IP历史记录 - 只保存IP部分,不包含端口
    QString ip = addr.split(":").first();
    if (!ip.isEmpty()) {
        saveIpHistory(ip);
    }
    
    // 保存端口历史记录
    QString port = addr.split(":").last();
    if (!port.isEmpty() && port != ip) {
        savePortHistory(port);
    }

    outLog("wireless connect...", false);
    QStringList adbArgs;
    adbArgs << "connect";
    adbArgs << addr;
    m_adb.execute("", adbArgs);
}

void Dialog::on_startAdbdBtn_clicked()
{
    if (checkAdbRun()) {
        return;
    }
    outLog("start devices adbd...", false);
    // adb tcpip 5555
    QStringList adbArgs;
    adbArgs << "tcpip";
    adbArgs << "5555";
    m_adb.execute(ui->serialBox->currentText().trimmed(), adbArgs);
}

void Dialog::outLog(const QString &log, bool newLine)
{
    // avoid sub thread update ui
    QString backLog = log;
    // The Windows GUI process does not reliably forward Qt's default
    // message handler to redirected stderr. Persist every visible log line
    // so a session can verify the exact same text as outEdit.
    if (true) {
        QFile file(QCoreApplication::applicationDirPath() + QStringLiteral("/startup.stderr.log"));
        if (file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
            const QByteArray line = (QDateTime::currentDateTimeUtc().toString(
                        QStringLiteral("yyyy-MM-ddTHH:mm:ss.zzzZ ")) + backLog + QLatin1Char('\n')).toUtf8();
            file.write(line);
            file.close();
        }
    }
    QTimer::singleShot(0, this, [this, backLog, newLine]() {
        ui->outEdit->append(backLog);
        if (newLine) {
            ui->outEdit->append("<br/>");
        }
    });
}

bool Dialog::filterLog(const QString &log)
{
    if (log.contains("app_proces")) {
        return true;
    }
    if (log.contains("Unable to set geometry")) {
        return true;
    }
    return false;
}

bool Dialog::checkAdbRun()
{
    if (m_adb.isRuning()) {
        outLog("wait for the end of the current command to run");
    }
    return m_adb.isRuning();
}

void Dialog::on_getIPBtn_clicked()
{
    if (checkAdbRun()) {
        return;
    }

    outLog("get ip...", false);
    // adb -s P7C0218510000537 shell ifconfig wlan0
    // or
    // adb -s P7C0218510000537 shell ip -f inet addr show wlan0
    QStringList adbArgs;
#if 0
    adbArgs << "shell";
    adbArgs << "ip";
    adbArgs << "-f";
    adbArgs << "inet";
    adbArgs << "addr";
    adbArgs << "show";
    adbArgs << "wlan0";
#else
    adbArgs << "shell";
    adbArgs << "ifconfig";
    adbArgs << "wlan0";
#endif
    m_adb.execute(ui->serialBox->currentText().trimmed(), adbArgs);
}

void Dialog::getIPbyIp()
{
    if (checkAdbRun()) {
        return;
    }

    QStringList adbArgs;
    adbArgs << "shell";
    adbArgs << "ip -o a";

    m_adb.execute(ui->serialBox->currentText().trimmed(), adbArgs);
}

void Dialog::onDeviceConnected(bool success, const QString &serial, const QString &deviceName, const QSize &size)
{
    Q_UNUSED(deviceName);
    const bool remote = serial.startsWith(QStringLiteral("relay/"));
    if (!success) {
        if (remote) {
            const QString message = tr("Remote connection failed for %1. Check host, ports, token, and that the relay and agent are running.").arg(serial);
            outLog(message);
            qWarning().noquote() << message;
        }
        return;
    }
    auto videoForm = new VideoForm(ui->framelessCheck->isChecked(), Config::getInstance().getSkin(), ui->showToolbar->isChecked(), ui->decodeModeBox->currentIndex());
    videoForm->setSerial(serial);

    auto device = qsc::IDeviceManage::getInstance().getDevice(serial);
    if (remote && !device) {
        const QString message = tr("Remote stream for %1 could not open: device connection is no longer available.").arg(serial);
        outLog(message);
        qWarning().noquote() << message;
        videoForm->deleteLater();
        return;
    }
    device->setUserData(static_cast<void*>(videoForm));
    device->registerDeviceObserver(videoForm);


    videoForm->showFPS(ui->fpsCheck->isChecked());

    if (ui->alwaysTopCheck->isChecked()) {
        videoForm->staysOnTop();
    }

#ifndef Q_OS_WIN32
    // must be show before updateShowSize
    videoForm->show();
#endif
    QString name = Config::getInstance().getNickName(serial);
    if (name.isEmpty()) {
        name = Config::getInstance().getTitle();
    }
    videoForm->setWindowTitle(name + "-" + serial);
    videoForm->updateShowSize(size);

    bool deviceVer = size.height() > size.width();
    QRect rc = Config::getInstance().getRect(serial);
    bool rcVer = rc.height() > rc.width();
    // same width/height rate
    if (rc.isValid() && (deviceVer == rcVer)) {
        // mark: resize is for fix setGeometry magneticwidget bug
        videoForm->resize(rc.size());
        videoForm->setGeometry(rc);
    }
    if (remote && !rc.isValid()) {
        QScreen *scr = screen() ? screen() : QGuiApplication::primaryScreen();
        if (scr) {
            const QRect avail = scr->availableGeometry();
            if (avail.isValid()) {
                videoForm->move(avail.center() - videoForm->rect().center());
            }
        }
    }
    if (remote) {
        const QString message = tr("Remote stream window opened for %1 (%2x%3).")
                .arg(serial).arg(size.width()).arg(size.height());
        outLog(message);
        qInfo().noquote() << message;
    }

#ifdef Q_OS_WIN32
    // windows是show太早可以看到resize的过程
    QTimer::singleShot(200, videoForm, [videoForm](){videoForm->show();});
#endif

    GroupController::instance().addDevice(serial);
}

void Dialog::onDeviceDisconnected(QString serial)
{
    if (serial.startsWith(QStringLiteral("relay/"))) {
        const QString message = tr("Remote stream disconnected for %1.").arg(serial);
        outLog(message);
        qInfo().noquote() << message;
    }
    GroupController::instance().removeDevice(serial);
    auto device = qsc::IDeviceManage::getInstance().getDevice(serial);
    if (!device) {
        return;
    }
    auto data = device->getUserData();
    if (data) {
        VideoForm* vf = static_cast<VideoForm*>(data);
        qsc::IDeviceManage::getInstance().getDevice(serial)->deRegisterDeviceObserver(vf);
        vf->close();
        vf->deleteLater();
    }
}

void Dialog::on_wirelessDisConnectBtn_clicked()
{
    if (checkAdbRun()) {
        return;
    }
    QString addr = ui->deviceIpEdt->currentText().trimmed();
    outLog("wireless disconnect...", false);
    QStringList adbArgs;
    adbArgs << "disconnect";
    adbArgs << addr;
    m_adb.execute("", adbArgs);
}

void Dialog::on_selectRecordPathBtn_clicked()
{
    QFileDialog::Options options = QFileDialog::DontResolveSymlinks | QFileDialog::ShowDirsOnly;
    QString directory = QFileDialog::getExistingDirectory(this, tr("select path"), "", options);
    ui->recordPathEdt->setText(directory);
}

void Dialog::on_recordPathEdt_textChanged(const QString &arg1)
{
    ui->recordPathEdt->setToolTip(arg1.trimmed());
    ui->notDisplayCheck->setCheckable(!arg1.trimmed().isEmpty());
}

void Dialog::on_adbCommandBtn_clicked()
{
    execAdbCmd();
}

void Dialog::on_stopAdbBtn_clicked()
{
    m_adb.kill();
}

void Dialog::on_clearOut_clicked()
{
    ui->outEdit->clear();
}

void Dialog::on_stopAllServerBtn_clicked()
{
    qsc::IDeviceManage::getInstance().disconnectAllDevice();
}

void Dialog::on_refreshGameScriptBtn_clicked()
{
    ui->gameBox->clear();
    initializeKeyMapDirectory();
    const QDir userDir(getKeyMapPath());
    const QDir defaultDir(getDefaultKeyMapPath());
    if (!userDir.exists() && !defaultDir.exists()) {
        outLog("keymap directory not find", true);
        return;
    }
    QSet<QString> fileNames;
    const QList<QDir> directories {userDir, defaultDir};
    for (const QDir &dir : directories) {
        const QFileInfoList list = dir.entryInfoList(QStringList() << "*.json", QDir::Files | QDir::NoSymLinks);
        for (const QFileInfo &fileInfo : list) {
            if (!fileNames.contains(fileInfo.fileName())) {
                fileNames.insert(fileInfo.fileName());
                ui->gameBox->addItem(fileInfo.fileName());
            }
        }
    }
}

void Dialog::on_applyScriptBtn_clicked()
{
    auto curSerial = ui->serialBox->currentText().trimmed();
    auto device = qsc::IDeviceManage::getInstance().getDevice(curSerial);
    if (!device) {
        return;
    }

    device->updateScript(getGameScript(ui->gameBox->currentText()));
}

void Dialog::on_recordScreenCheck_clicked(bool checked)
{
    if (!checked) {
        return;
    }

    QString fileDir(ui->recordPathEdt->text().trimmed());
    if (fileDir.isEmpty()) {
        qWarning() << "please select record save path!!!";
        ui->recordScreenCheck->setChecked(false);
    }
}

void Dialog::on_usbConnectBtn_clicked()
{
    on_stopAllServerBtn_clicked();
    delayMs(200);
    on_updateDevice_clicked();
    delayMs(200);

    int firstUsbDevice = findDeviceFromeSerialBox(false);
    if (-1 == firstUsbDevice) {
        qWarning() << "No use device is found!";
        return;
    }
    ui->serialBox->setCurrentIndex(firstUsbDevice);

    on_startServerBtn_clicked();
}

int Dialog::findDeviceFromeSerialBox(bool wifi)
{
    QString regStr = "\\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\:([0-9]|[1-9]\\d|[1-9]\\d{2}|[1-9]\\d{3}|[1-5]\\d{4}|6[0-4]\\d{3}|65[0-4]\\d{2}|655[0-2]\\d|6553[0-5])\\b";
#if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
    QRegExp regIP(regStr);
#else
    QRegularExpression regIP(regStr);
#endif
    for (int i = 0; i < ui->serialBox->count(); ++i) {
#if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
        bool isWifi = regIP.exactMatch(ui->serialBox->itemText(i));
#else
        bool isWifi = regIP.match(ui->serialBox->itemText(i)).hasMatch();
#endif
        bool found = wifi ? isWifi : !isWifi;
        if (found) {
            return i;
        }
    }

    return -1;
}

void Dialog::on_wifiConnectBtn_clicked()
{
    on_stopAllServerBtn_clicked();
    delayMs(200);

    on_updateDevice_clicked();
    delayMs(200);

    int firstUsbDevice = findDeviceFromeSerialBox(false);
    if (-1 == firstUsbDevice) {
        qWarning() << "No use device is found!";
        return;
    }
    ui->serialBox->setCurrentIndex(firstUsbDevice);

    on_getIPBtn_clicked();
    delayMs(200);

    on_startAdbdBtn_clicked();
    delayMs(1000);

    on_wirelessConnectBtn_clicked();
    delayMs(2000);

    on_updateDevice_clicked();
    delayMs(200);

    int firstWifiDevice = findDeviceFromeSerialBox(true);
    if (-1 == firstWifiDevice) {
        qWarning() << "No wifi device is found!";
        return;
    }
    ui->serialBox->setCurrentIndex(firstWifiDevice);

    on_startServerBtn_clicked();
}

void Dialog::on_connectedPhoneList_itemDoubleClicked(QListWidgetItem *item)
{
    Q_UNUSED(item);
    ui->serialBox->setCurrentIndex(ui->connectedPhoneList->currentRow());
    on_startServerBtn_clicked();
}

void Dialog::on_updateNameBtn_clicked()
{
    if (ui->serialBox->count() != 0) {
        if (ui->userNameEdt->text().isEmpty()) {
            Config::getInstance().setNickName(ui->serialBox->currentText(), "Phone");
        } else {
            Config::getInstance().setNickName(ui->serialBox->currentText(), ui->userNameEdt->text());
        }

        on_updateDevice_clicked();

        qDebug() << "Update OK!";
    } else {
        qWarning() << "No device is connected!";
    }
}

void Dialog::on_useSingleModeCheck_clicked()
{
    if (m_mainPages) return;
    if (ui->useSingleModeCheck->isChecked()) {
        ui->rightWidget->hide();
    } else {
        ui->rightWidget->show();
    }

    adjustSize();
}

void Dialog::on_serialBox_currentIndexChanged(const QString &arg1)
{
    ui->userNameEdt->setText(Config::getInstance().getNickName(arg1));
}

quint32 Dialog::getBitRate()
{
    return ui->bitRateEdit->text().trimmed().toUInt() *
            (ui->bitRateBox->currentText() == QString("Mbps") ? 1000000 : 1000);
}

const QString &Dialog::getServerPath()
{
    static QString serverPath;
    if (serverPath.isEmpty()) {
        serverPath = QString::fromLocal8Bit(qgetenv("QTSCRCPY_SERVER_PATH"));
        QFileInfo fileInfo(serverPath);
        if (serverPath.isEmpty() || !fileInfo.isFile()) {
            serverPath = QCoreApplication::applicationDirPath() + "/scrcpy-server";
        }
    }
    return serverPath;
}

void Dialog::on_startAudioBtn_clicked()
{
    if (ui->serialBox->count() == 0) {
        qWarning() << "No device is connected!";
        return;
    }

    m_audioOutput.start(ui->serialBox->currentText(), 28200);
}

void Dialog::on_stopAudioBtn_clicked()
{
    m_audioOutput.stop();
}

void Dialog::on_installSndcpyBtn_clicked()
{
    if (ui->serialBox->count() == 0) {
        qWarning() << "No device is connected!";
        return;
    }
    m_audioOutput.installonly(ui->serialBox->currentText(), 28200);
}

void Dialog::on_autoUpdatecheckBox_toggled(bool checked)
{
    if (checked) {
        m_autoUpdatetimer.start(5000);
    } else {
        m_autoUpdatetimer.stop();
    }
}

void Dialog::loadIpHistory()
{
    QStringList ipList = Config::getInstance().getIpHistory();
    ui->deviceIpEdt->clear();
    ui->deviceIpEdt->addItems(ipList);

    if (ui->deviceIpEdt->lineEdit()) {
        ui->deviceIpEdt->lineEdit()->setFrame(false);
        ui->deviceIpEdt->lineEdit()->setTextMargins(0, 0, 0, 0);
        ui->deviceIpEdt->lineEdit()->setMaxLength(128);
        ui->deviceIpEdt->lineEdit()->setPlaceholderText("192.168.0.1");
    }
}

void Dialog::saveIpHistory(const QString &ip)
{
    if (ip.isEmpty()) {
        return;
    }
    
    Config::getInstance().saveIpHistory(ip);
    
    // 更新ComboBox
    loadIpHistory();
    ui->deviceIpEdt->setCurrentText(ip);
}

void Dialog::showIpEditMenu(const QPoint &pos)
{
    QMenu *menu = ui->deviceIpEdt->lineEdit()->createStandardContextMenu();
    menu->addSeparator();
    
    QAction *clearHistoryAction = new QAction(tr("Clear History"), menu);
    connect(clearHistoryAction, &QAction::triggered, this, [this]() {
        Config::getInstance().clearIpHistory();
        loadIpHistory();
    });
    
    menu->addAction(clearHistoryAction);
    menu->exec(ui->deviceIpEdt->lineEdit()->mapToGlobal(pos));
    delete menu;
}

void Dialog::loadPortHistory()
{
    QStringList portList = Config::getInstance().getPortHistory();
    ui->devicePortEdt->clear();
    ui->devicePortEdt->addItems(portList);

    if (ui->devicePortEdt->lineEdit()) {
        ui->devicePortEdt->lineEdit()->setFrame(false);
        ui->devicePortEdt->lineEdit()->setTextMargins(0, 0, 0, 0);
        ui->devicePortEdt->lineEdit()->setMaxLength(6);
        ui->devicePortEdt->lineEdit()->setPlaceholderText("5555");
    }
}

void Dialog::savePortHistory(const QString &port)
{
    if (port.isEmpty()) {
        return;
    }
    
    Config::getInstance().savePortHistory(port);
    
    // 更新ComboBox
    loadPortHistory();
    ui->devicePortEdt->setCurrentText(port);
}

void Dialog::showPortEditMenu(const QPoint &pos)
{
    QMenu *menu = ui->devicePortEdt->lineEdit()->createStandardContextMenu();
    menu->addSeparator();
    
    QAction *clearHistoryAction = new QAction(tr("Clear History"), menu);
    connect(clearHistoryAction, &QAction::triggered, this, [this]() {
        Config::getInstance().clearPortHistory();
        loadPortHistory();
    });
    
    menu->addAction(clearHistoryAction);
    menu->exec(ui->devicePortEdt->lineEdit()->mapToGlobal(pos));
    delete menu;
}


void Dialog::on_codecModeBox_currentIndexChanged(int index)
{
    // Block signals while updating bitrate to avoid recursive calls
    ui->bitRateEdit->blockSignals(true);
    ui->bitRateBox->blockSignals(true);

    const EncoderPreset *preset = nullptr;
    if (index > 0) {
        preset = &EncoderPresetRegistry::all().at(index - 1);
    }

    if (index == 0) {
        // Default: restore previous settings
        if (m_prevBitRate == 0) {
            ui->bitRateEdit->setText("2");
            ui->bitRateBox->setCurrentText("Mbps");
        } else if (m_prevBitRate % 1000000 == 0) {
            ui->bitRateEdit->setText(QString::number(m_prevBitRate / 1000000));
            ui->bitRateBox->setCurrentText("Mbps");
        } else {
            ui->bitRateEdit->setText(QString::number(m_prevBitRate / 1000));
            ui->bitRateBox->setCurrentText("Kbps");
        }
        // Restore previous max size
        ui->maxSizeBox->setCurrentIndex(m_prevMaxSizeIndex);
    } else {
        // Preset mode: save current settings for Default-mode restoration
        m_prevBitRate = getBitRate();
        m_prevMaxSizeIndex = ui->maxSizeBox->currentIndex();

        // Sync bitrate & maxSize to match the saved encoder tier
        UserBootConfig config = Config::getInstance().getUserBootConfig();
        int level = config.presetLevel;
        quint32 bitrate = preset->levelBitRate(level);
        if (bitrate > 0) {
            if (bitrate % 1000000 == 0) {
                ui->bitRateEdit->setText(QString::number(bitrate / 1000000));
                ui->bitRateBox->setCurrentText("Mbps");
            } else {
                ui->bitRateEdit->setText(QString::number(bitrate / 1000));
                ui->bitRateBox->setCurrentText("Kbps");
            }
        }
        int maxSizeIdx = preset->levelMaxSizeIndex(level);
        if (maxSizeIdx >= 0) {
            ui->maxSizeBox->setCurrentIndex(maxSizeIdx);
        }
    }

    // Show the encoder settings button only for presets with adjustable tiers
    ui->presetConfigBtn->setVisible(preset && preset->levelCount() >= 2);

    ui->bitRateEdit->blockSignals(false);
    ui->bitRateBox->blockSignals(false);
}

void Dialog::on_presetConfigBtn_clicked()
{
    const int codecModeIndex = ui->codecModeBox->currentIndex();
    if (codecModeIndex <= 0) {
        return;
    }
    const EncoderPreset &preset = EncoderPresetRegistry::all().at(codecModeIndex - 1);

    // (Re)create the dialog when the selected preset changes.
    if (!m_presetDialog || m_presetDialog->presetId() != preset.id) {
        m_presetDialog = new PresetConfigDialog(preset, this);
        // Only restore the saved tier on first creation — subsequent opens
        // preserve the user's last selection in the dialog.
        UserBootConfig bootConfig = Config::getInstance().getUserBootConfig();
        m_presetDialog->setLevel(bootConfig.presetLevel);

        // Sync bitrate & maxSize UI in real-time as the user switches tiers.
        connect(m_presetDialog.data(), &PresetConfigDialog::levelChanged,
                this, &Dialog::syncPresetLevelToUi);
    }

    m_presetDialog->exec();

    // Sync after dialog closes — covers the case where the initial tier was
    // restored via setLevel() above and no levelChanged signal fired.
    syncPresetLevelToUi();
}

void Dialog::syncPresetLevelToUi()
{
    const int codecModeIndex = ui->codecModeBox->currentIndex();
    if (codecModeIndex <= 0 || !m_presetDialog) {
        return;
    }
    const EncoderPreset &preset = EncoderPresetRegistry::all().at(codecModeIndex - 1);
    int level = m_presetDialog->selectedLevel();

    // Update bitrate
    quint32 bitrate = preset.levelBitRate(level);
    if (bitrate > 0) {
        ui->bitRateEdit->blockSignals(true);
        ui->bitRateBox->blockSignals(true);
        if (bitrate % 1000000 == 0) {
            ui->bitRateEdit->setText(QString::number(bitrate / 1000000));
            ui->bitRateBox->setCurrentText("Mbps");
        } else {
            ui->bitRateEdit->setText(QString::number(bitrate / 1000));
            ui->bitRateBox->setCurrentText("Kbps");
        }
        ui->bitRateEdit->blockSignals(false);
        ui->bitRateBox->blockSignals(false);
    }

    // Update max size (only when the tier prescribes one)
    int maxSizeIdx = preset.levelMaxSizeIndex(level);
    if (maxSizeIdx >= 0) {
        ui->maxSizeBox->setCurrentIndex(maxSizeIdx);
    }
}
