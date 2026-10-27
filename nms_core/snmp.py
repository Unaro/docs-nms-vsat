import asyncio
import logging
from typing import Any, Dict, List
import aiosnmp
from .parsers import decode_val, format_mac, format_uptime

logger = logging.getLogger("nms-snmp")

class SnmpClient:
    @staticmethod
    def _clean_oid(oid: str) -> str:
        return oid.lstrip(".")

    @classmethod
    async def safe_walk(cls, snmp: aiosnmp.Snmp, root_oid: str, max_repetitions: int = 15) -> List[Any]:
        """
        Обход MIB-дерева через aiosnmp.
        aiosnmp.Snmp.bulk_walk принимает OID одиночной строкой (str)
        и возвращает список SnmpVarbind при обычном await.
        """
        oid_str = str(root_oid).strip()
        try:
            res = await snmp.bulk_walk(oid_str, max_repetitions=max_repetitions)
            return res if res is not None else []
        except Exception as exc:
            logger.debug(f"bulk_walk failed for {oid_str} ({exc}), falling back to walk()")
            try:
                res = await snmp.walk(oid_str)
                return res if res is not None else []
            except Exception as exc2:
                logger.warning(f"Both bulk_walk and walk failed for {oid_str}: {exc2}")
                return []

    @classmethod
    async def get_scalars(
        cls,
        host: str,
        port: int,
        community: str,
        target_oids: Dict[str, str],
        timeout_sec: float = 2.0,
        retries: int = 1
    ) -> Dict[str, Any]:
        oid_to_key = {cls._clean_oid(oid): key for key, oid in target_oids.items()}
        request_oids = list(oid_to_key.keys())

        try:
            async with aiosnmp.Snmp(host=host, port=port, community=community, timeout=timeout_sec, retries=retries) as snmp:
                results = await snmp.get(request_oids)
                metrics = {}
                for vb in results:
                    c_oid = cls._clean_oid(str(vb.oid))
                    key = oid_to_key.get(c_oid, c_oid)
                    metrics[key] = decode_val(vb.value)
                return {"ok": True, "data": metrics, "error": None}
        except Exception as exc:
            return {"ok": False, "data": {}, "error": str(exc)}

    @classmethod
    async def deep_inspect(
        cls,
        host: str,
        port: int,
        community: str,
        timeout_sec: float = 2.5
    ) -> Dict[str, Any]:
        output = {
            "ok": False,
            "error": None,
            "system": {},
            "hardware": {"cpu_percent": None, "ram_total_mb": None, "ram_used_mb": None, "ram_percent": None},
            "interfaces": []
        }

        try:
            async with aiosnmp.Snmp(host=host, port=port, community=community, timeout=timeout_sec, retries=1) as snmp:
                # 1. Системные скаляры MIB-II
                sys_oids = [
                    "1.3.6.1.2.1.1.1.0", # sysDescr
                    "1.3.6.1.2.1.1.2.0", # sysObjectID
                    "1.3.6.1.2.1.1.3.0", # sysUpTime
                    "1.3.6.1.2.1.1.4.0", # sysContact
                    "1.3.6.1.2.1.1.5.0", # sysName
                    "1.3.6.1.2.1.1.6.0"  # sysLocation
                ]
                try:
                    res = await snmp.get(sys_oids)
                    output["ok"] = True
                    for vb in res:
                        c_oid = cls._clean_oid(str(vb.oid))
                        v = decode_val(vb.value)
                        if c_oid == "1.3.6.1.2.1.1.1.0": output["system"]["descr"] = v
                        elif c_oid == "1.3.6.1.2.1.1.2.0": output["system"]["object_id"] = str(v)
                        elif c_oid == "1.3.6.1.2.1.1.3.0":
                            raw_ticks = int(v) if str(v).isdigit() else 0
                            output["system"]["uptime_raw"] = raw_ticks
                            output["system"]["uptime_str"] = format_uptime(raw_ticks)
                        elif c_oid == "1.3.6.1.2.1.1.4.0": output["system"]["contact"] = v or "—"
                        elif c_oid == "1.3.6.1.2.1.1.5.0": output["system"]["name"] = v
                        elif c_oid == "1.3.6.1.2.1.1.6.0": output["system"]["location"] = v or "—"
                except Exception as e:
                    output["error"] = f"Failed to get system scalars: {e}"
                    return output

                # 2. CPU: Сначала пробуем Host Resources (hrProcessorLoad)
                try:
                    hr_cpu = await cls.safe_walk(snmp, "1.3.6.1.2.1.25.3.3.1.2")
                    loads = [int(vb.value) for vb in hr_cpu if vb.value is not None and str(vb.value).isdigit()]
                    if loads:
                        output["hardware"]["cpu_percent"] = int(sum(loads) / len(loads))
                except Exception as e:
                    logger.debug(f"Host Resources CPU probe: {e}")

                # Если Host Resources не ответил, опрашиваем Net-SNMP (ssCpuUser + ssCpuSystem / ssCpuIdle)
                if output["hardware"]["cpu_percent"] is None:
                    try:
                        cpu_vbs = await snmp.get([
                            "1.3.6.1.4.1.2021.11.9.0",  # ssCpuUser
                            "1.3.6.1.4.1.2021.11.10.0", # ssCpuSystem
                            "1.3.6.1.4.1.2021.11.11.0"  # ssCpuIdle
                        ])
                        vals = {cls._clean_oid(str(vb.oid)): vb.value for vb in cpu_vbs if vb.value is not None}
                        u = vals.get("1.3.6.1.4.1.2021.11.9.0")
                        s = vals.get("1.3.6.1.4.1.2021.11.10.0")
                        i = vals.get("1.3.6.1.4.1.2021.11.11.0")

                        if u is not None and s is not None and str(u).isdigit() and str(s).isdigit():
                            output["hardware"]["cpu_percent"] = min(100, int(u) + int(s))
                        elif i is not None and str(i).isdigit():
                            output["hardware"]["cpu_percent"] = max(0, 100 - int(i))
                    except Exception as e:
                        logger.debug(f"Net-SNMP CPU probe: {e}")

                # 3. RAM (memTotalReal и memAvailReal)
                try:
                    mem_vbs = await snmp.get(["1.3.6.1.4.1.2021.4.5.0", "1.3.6.1.4.1.2021.4.6.0"])
                    if len(mem_vbs) == 2 and str(mem_vbs[0].value).isdigit() and str(mem_vbs[1].value).isdigit():
                        tot = int(mem_vbs[0].value)
                        avl = int(mem_vbs[1].value)
                        used = tot - avl
                        output["hardware"]["ram_total_mb"] = tot // 1024
                        output["hardware"]["ram_used_mb"] = used // 1024
                        output["hardware"]["ram_percent"] = round((used / tot) * 100, 1)
                except Exception as e:
                    logger.debug(f"RAM probe: {e}")

                # 4. IF-MIB интерфейсы
                ifaces: Dict[str, Dict[str, Any]] = {}
                try:
                    # Имена интерфейсов (ifDescr)
                    descr_list = await cls.safe_walk(snmp, "1.3.6.1.2.1.2.2.1.2")
                    for vb in descr_list:
                        idx = str(vb.oid).split(".")[-1]
                        ifaces[idx] = {
                            "index": int(idx),
                            "name": decode_val(vb.value),
                            "mac": "—",
                            "oper_status": "down",
                            "speed_mbps": 0,
                            "in_octets": 0,
                            "out_octets": 0,
                        }

                    # MAC-адреса (ifPhysAddress)
                    mac_list = await cls.safe_walk(snmp, "1.3.6.1.2.1.2.2.1.6")
                    for vb in mac_list:
                        idx = str(vb.oid).split(".")[-1]
                        if idx in ifaces:
                            ifaces[idx]["mac"] = format_mac(vb.value)

                    # Оперативные статусы (ifOperStatus: 1=up, 2=down)
                    oper_list = await cls.safe_walk(snmp, "1.3.6.1.2.1.2.2.1.8")
                    for vb in oper_list:
                        idx = str(vb.oid).split(".")[-1]
                        if idx in ifaces:
                            ifaces[idx]["oper_status"] = "up" if str(vb.value) == "1" else "down"

                    # Скорости линков (ifSpeed)
                    speed_list = await cls.safe_walk(snmp, "1.3.6.1.2.1.2.2.1.5")
                    for vb in speed_list:
                        idx = str(vb.oid).split(".")[-1]
                        if idx in ifaces:
                            raw = int(vb.value) if str(vb.value).isdigit() else 0
                            ifaces[idx]["speed_mbps"] = raw // 1_000_000

                    # Входящие байты (ifInOctets)
                    in_list = await cls.safe_walk(snmp, "1.3.6.1.2.1.2.2.1.10")
                    for vb in in_list:
                        idx = str(vb.oid).split(".")[-1]
                        if idx in ifaces and str(vb.value).isdigit():
                            ifaces[idx]["in_octets"] = int(vb.value)

                    # Исходящие байты (ifOutOctets)
                    out_list = await cls.safe_walk(snmp, "1.3.6.1.2.1.2.2.1.16")
                    for vb in out_list:
                        idx = str(vb.oid).split(".")[-1]
                        if idx in ifaces and str(vb.value).isdigit():
                            ifaces[idx]["out_octets"] = int(vb.value)

                    output["interfaces"] = sorted(list(ifaces.values()), key=lambda x: x["index"])
                except Exception as e:
                    logger.warning(f"Interfaces table parsing failed: {e}")

                return output

        except Exception as exc:
            output["error"] = str(exc)
            return output