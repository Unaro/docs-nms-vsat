# 1. Продукты и условия сравнения

## 1.1 Состав расширенного сравнения

В исследование включены универсальные NMS, облачные платформы наблюдаемости, системы управления сетями производителей и DCIM. Они не являются полностью взаимозаменяемыми, поэтому в сравнении нужно разделять общий мониторинг, управление сетью, автоматизацию и управление инфраструктурой площадки.

| Группа | Продукты |
|---|---|
| Классические NMS | PRTG, Zabbix, OpenNMS, SolarWinds NPM, ManageEngine OpManager, Nagios, WhatsUp Gold, LibreNMS, Checkmk |
| Облачный мониторинг и наблюдаемость | Amazon CloudWatch, Datadog, LogicMonitor, Auvik, Kentik, ScienceLogic SL1 |
| Управление, контроль качества и автоматизация сети | Cisco Meraki Dashboard, HPE Aruba Central, Juniper Mist, NetBrain |
| DCIM и инфраструктура площадки | Sunbird, ABB Decathlon, CenterOS |
| Производительские и операторские платформы | Cisco Nexus / Nexus Dashboard, Huawei iMaster NCE, Nokia NSP, Cambium cnMaestro |

## 1.2 Уточнение объектов сравнения

| Указанное название | Объект сравнения | Назначение | Развёртывание / условия | Статус идентификации |
|---|---|---|---|---|
| Paessler PRTG | PRTG Network Monitor | Классический мониторинг сети и инфраструктуры | Самостоятельное развёртывание; возможности зависят от редакции/лицензии | Подтверждён |
| Zabbix | Zabbix | Мониторинг, события, шаблоны, пользовательские проверки | Self-hosted; open-source, коммерческая поддержка отдельно | Подтверждён |
| OpenNMS | Horizon или Meridian | Сетевая NMS и event management | Self-hosted; ветки различаются поддержкой и функциями | Нужно выбрать ветку |
| SolarWinds | Network Performance Monitor (NPM) | Производительность и доступность сети | Коммерческий продукт; модули и платформа уточняются | Нужно подтвердить NPM |
| ManageEngine | OpManager | Мониторинг сетевых устройств и инфраструктуры | On-prem/cloud и редакции отличаются | Нужно подтвердить OpManager, не весь портфель |
| Nagios | Nagios XI; Core — отдельно при необходимости | Host/service monitoring и плагины | Core — open source, XI — коммерческий | Нужно выбрать XI/Core |
| WhatsUp Gold | WhatsUp Gold | Мониторинг сети, карт, событий и отчётов | Коммерческое развёртывание; пакет и версия влияют на функции | Подтверждён на уровне семейства |
| LibreNMS | LibreNMS | Open-source SNMP/network monitoring | Self-hosted | Подтверждён |
| Checkmk | Checkmk Raw и коммерческая редакция | Host/service monitoring, discovery, правила | Self-hosted; Raw и коммерческие редакции различаются | Подтверждён, редакцию выбрать |
| Amazon CloudWatch | CloudWatch | Метрики, логи, события, alarms и dashboards AWS | Managed AWS service; стоимость зависит от использования | Подтверждён |
| Datadog | Infrastructure Monitoring и нужные модули | SaaS infrastructure/observability | SaaS; Network Monitoring, Logs, APM и другие модули тарифицируются отдельно | Подтверждён, модули выбрать |
| LogicMonitor | LogicMonitor platform | SaaS infrastructure monitoring, collectors, dashboards | SaaS; функции зависят от пакета | Подтверждён |
| Auvik | Auvik Network Monitoring and Management | SaaS monitoring, discovery, topology, удалённые площадки | SaaS и MSP-oriented функции | Подтверждён |
| Kentik | Kentik Network Observability | Flow, traffic и path performance analytics | SaaS; источники потоков и retention влияют на доступность | Подтверждён |
| ScienceLogic | SL1 | Enterprise hybrid observability и event correlation | Коммерческая платформа; редакция требует уточнения | Подтверждён на уровне платформы |
| NetBrain | NetBrain | Dynamic mapping, диагностика и automation/runbooks | Коммерческая network automation platform | Подтверждён как отдельный класс |
| Cisco Meraki | Meraki Dashboard | Cloud management для поддерживаемых устройств Cisco Meraki | SaaS; зависит от оборудования и лицензии | Подтверждён |
| HPE Aruba | Aruba Central | Cloud management и assurance LAN/WLAN/SD-WAN | SaaS; поддерживаемые устройства и подписки важны | Подтверждён |
| Juniper | Mist / Mist AI | Cloud network assurance и client experience | SaaS; функции зависят от лицензий/устройств | Подтверждён |
| Sunbird | dcTrack и/или Power IQ | DCIM: активы, стойки, питание, охлаждение | Коммерческий DCIM; продукт нужно выбрать | Нужно уточнить продукт |
| ABB | Decathlon for Data Centers | Управление инфраструктурой ЦОД | Коммерческое проектное решение; модули зависят от проекта | Подтверждён на уровне семейства |
| CenterOS | CenterOS DCIM | Предположительно DCIM | Публичные сведения, версия и поставщик требуют проверки | Не подтверждён |
| Cisco Nexus | Nexus Dashboard и/или NX-OS telemetry | Управление/наблюдение Cisco fabric, не универсальная NMS | Зависит от модели, NX-OS и лицензии | Не сравнивать с NMS без Nexus Dashboard |
| Huawei | iMaster NCE | Controller/network management для Huawei-сетей | Vendor/carrier-specific; регион и лицензия важны | Подтверждён на уровне семейства |
| Nokia | NSP | Carrier network service, assurance и automation | Operator/carrier platform | Подтверждён на уровне платформы |
| Cambium | cnMaestro | Управление поддерживаемыми Cambium-сетями | Cloud или on-prem; vendor-specific | Подтверждён |
| IBM Data Center Services | Конкретный SKU/портал IBM не определён | Портфель услуг, не однозначный продукт NMS | Зависит от контракта и услуги | Исключить из количественного сравнения до уточнения |

## 1.3 Как использовать системы в сравнении

| Слой сравнения | Системы | Что изучать |
|---|---|---|
| Базовое ядро NMS | PRTG, Zabbix, OpenNMS, SolarWinds, OpManager, Nagios, WhatsUp Gold, LibreNMS, Checkmk | Инвентаризация, опрос, метрики, аварии, графики, роли |
| SaaS и наблюдаемость | CloudWatch, Datadog, LogicMonitor, Auvik, Kentik, ScienceLogic | Облачный UX, collectors, custom metrics, flow, retention, multi-tenancy |
| Assurance и автоматизация | NetBrain, Meraki, Aruba, Mist, Huawei, Nokia, Cisco Nexus | Топология, влияние на сервис, конфигурация, runbook, автоматизация |
| Физическая инфраструктура | Sunbird, ABB, CenterOS | Площадки, активы, стойки, питание, охлаждение, capacity |
| VSAT-домен | Специализированные системы конкретных модемов/хабов, плюс адаптеры собственной NMS | RF-метрики, carrier, beam, registration, MODCOD, BUC/LNB и allocation |

## 1.4 Что нельзя считать подтверждённым автоматически

- Generic NMS не гарантирует наличие SNR, C/N, Es/N₀, Eb/N₀, MODCOD, EIRP, ranging или BUC/LNB state.
- Наличие карты не означает наличие спутникового покрытия и лучей.
- Наличие графиков не означает наличие корректной модели спутниковой ёмкости.
- Наличие API не означает возможность безопасно выполнять команды.
- Наличие RBAC не означает полноценную multi-tenancy или изоляцию данных клиентов.
- Наличие названия продукта не подтверждает конкретную редакцию, модуль или номер версии.

## 1.5 Официальные точки проверки

| Система | Источник |
|---|---|
| PRTG | [Manuals](https://www.paessler.com/manuals/prtg) |
| Zabbix | [Documentation](https://www.zabbix.com/documentation/current/en/manual) |
| OpenNMS | [Documentation](https://docs.opennms.com/) |
| SolarWinds | [NPM](https://www.solarwinds.com/network-performance-monitor) · [Documentation](https://documentation.solarwinds.com/) |
| ManageEngine | [OpManager](https://www.manageengine.com/network-monitoring/) · [Help](https://www.manageengine.com/network-monitoring/help/) |
| Nagios | [Documentation](https://www.nagios.org/documentation/) · [Nagios XI](https://www.nagios.com/products/nagios-xi/) |
| WhatsUp Gold | [Product](https://www.whatsupgold.com/) · [Documentation](https://docs.whatsupgold.com/) |
| LibreNMS | [Site](https://www.librenms.org/) · [Docs](https://docs.librenms.org/) |
| Checkmk | [Product](https://checkmk.com/product) · [Docs](https://docs.checkmk.com/) |
| CloudWatch | [Documentation](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/WhatIsCloudWatch.html) |
| Datadog | [Infrastructure docs](https://docs.datadoghq.com/infrastructure/) |
| LogicMonitor | [Product](https://www.logicmonitor.com/) · [Support](https://www.logicmonitor.com/support) |
| Auvik | [Site](https://www.auvik.com/) · [Help](https://help.auvik.com/) |
| Kentik | [Site](https://www.kentik.com/) · [Knowledge Base](https://kb.kentik.com/) |
| ScienceLogic | [Platform](https://sciencelogic.com/platform/) · [Docs](https://docs.sciencelogic.com/) |
| NetBrain | [Site](https://www.netbraintech.com/) |
| Meraki | [Dashboard overview](https://documentation.meraki.com/General_Administration/Monitoring_and_Reporting/Dashboard_Overview) · [API](https://developer.cisco.com/meraki/api-v1/) |
| Aruba Central | [Product](https://www.hpe.com/us/en/aruba-central.html) · [Docs](https://www.arubanetworks.com/techdocs/central/latest/content/home.htm) |
| Juniper Mist | [Product](https://www.juniper.net/us/en/products/cloud-services/mist-ai.html) · [Docs](https://www.juniper.net/documentation/us/en/software/mist/) |
| Sunbird | [DCIM](https://www.sunbirddcim.com/) |
| ABB | [Data center solutions](https://new.abb.com/data-centers) |
| Cisco | [Nexus Dashboard](https://www.cisco.com/c/en/us/support/cloud-systems-management/nexus-dashboard/series.html) |
| Huawei | [Network management](https://e.huawei.com/en/products/network-management) |
| Nokia | [NSP](https://www.nokia.com/networks/automation/network-services-platform/) |
| Cambium | [cnMaestro](https://www.cambiumnetworks.com/products/software/cnmaestro/) |

Перед финальным сравнением необходимо зафиксировать редакцию, версию, вариант размещения, лицензируемые модули и дату документации. Ссылки на страницы не доказывают наличие каждой функции.
