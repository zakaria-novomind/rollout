#!/usr/bin/env python3

from abc import ABC
from dataclasses import dataclass
from datetime import datetime
import re
import sys
import json
import gzip
import configparser
import hashlib
import random


def is_valid_date(date_str):
    try:
        datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S.%f")
        return True
    except ValueError:
        return False


def get_hash(val: str):
    salt = "AG@p6JT,(a6<dndj"
    hash_val = val + salt
    return hashlib.md5(hash_val.encode(encoding)).hexdigest()[: len(val)]


def get_val(val):
    if val == "" or val == "\\N":
        val = val
    elif len(val) < 7 and not val.isnumeric():
        val = get_hash(val)
    elif is_valid_date(val):
        val = "2000-01-01 00:00:00.000"
    elif not val.isnumeric():
        val = "CLEARED"
    elif val.isnumeric():
        val = random.randint(0, 9)
    return str(val)


# data sections
@dataclass
class Base(ABC):
    name: str = None


@dataclass
class Column(Base):
    personal_data: bool = None
    position: int = None


@dataclass()
class Table(Base):
    column: Column = None
    truncate: bool = None

    def __eq__(self, obj):
        return (
            isinstance(obj, Table)
            and self.name == obj.name
            and self.column.name == obj.column.name
        )


if __name__ == "__main__":
    # ínit property file
    parser = configparser.SafeConfigParser()
    parser.read("config/dump_anonymizer.ini")

    # global vars
    pattern_start = parser.get("RegExPattern", "pattern_start")
    pattern_table = parser.get("RegExPattern", "pattern_table")
    pattern_columns = parser.get("RegExPattern", "pattern_columns")
    path_dump_file = parser.get("Files", "path_dump_file")
    path_anon_json_file = parser.get("Files", "path_anon_json_file", fallback=None)
    encoding = parser.get("Base", "encoding")

    client_host = parser.get("Client", "client_hostname")
    client_user = parser.get("Client", "client_username")
    client_pass = parser.get("Client", "client_password")

    dump_data = []
    with gzip.open(path_dump_file, "rb") as f:
        for line in f:
            line = line.decode(encoding)
            if line.startswith(pattern_start):
                table = re.findall(pattern_table, line)[0]
                columns = re.findall(pattern_columns, line)[0]
                for idx, column in enumerate(columns.split(", "), start=1):
                    dump_data.append(
                        Table(
                            name=table,
                            column=Column(
                                name=column, personal_data=False, position=idx
                            ),
                        )
                    )

    json_result_data = []
    if path_anon_json_file is None:
        sys.path.append("/usr/local/icinga2/libexec/")
        from rest_wrapper_total_time import ImarketAPIClient
        from rest_wrapper_total_time import AuthAPIClient

        headers = {"Content-Type": "application/json"}
        host = client_host
        port = 443
        client = ImarketAPIClient(
            host=host,
            endpoint="/anonymization/sections",
            port=port,
            headers=headers,
            auth_client=AuthAPIClient(
                host=host,
                username=client_user,
                password=client_pass,
                port=port,
                headers=headers,
            ),
        )
        json_result_data = json.loads(client.call().text).get("data")
    else:
        with open(path_anon_json_file, "r") as jf:
            json_result_data = json.load(jf).get("data")

    json_data = []
    for data in json_result_data:
        re_tables = data.get("tables")
        for re_table in re_tables:
            table = re_table.get("name")
            truncate = re_table.get("isToTruncate")
            if truncate:
                json_data.append(
                    Table(
                        name=table.lower(),
                        truncate=truncate,
                        column=Column(
                            name="not set", personal_data=False, position=None
                        ),
                    )
                )
            else:
                columns = re_table.get("columnsWithPersonalData")
                for column in columns:
                    column = column.get("name")
                    json_data.append(
                        Table(
                            name=table,
                            column=Column(
                                name=column, personal_data=True, position=None
                            ),
                        )
                    )

    del json_result_data
    for data in dump_data:
        if [
            x
            for x in [
                json_obj == data
                for json_obj in json_data
                if json_obj.column.personal_data is True
            ]
            if x is True
        ]:
            data.column.personal_data = True
        elif [
            x
            for x in [
                json_obj.name == data.name
                for json_obj in json_data
                if json_obj.column.name == "not set" and json_obj.truncate is True
            ]
            if x is True
        ]:
            data.column = None
            data.truncate = True

    personal_data = [
        i for i in dump_data if i.column is not None and i.column.personal_data is True
    ]
    truncate_data = list(
        set([data.name for data in dump_data if data.truncate is True])
    )

    del dump_data
    del json_data

    target_lines = False
    truncate_lines = False
    with gzip.open(path_dump_file, "rb") as df:
        for line in df:
            line = line.decode(encoding)
            if line.startswith(".", 1):
                target_lines = False
                truncate_lines = False
                print(line, end="")
            if [
                i
                for i in personal_data
                if i.name in line and i.column.name in line and pattern_start in line
            ]:
                search = re.search("^\\w+\\s\\w+\\.(\\w+)\\s", line)
                if search is not None:
                    table = search.group(1)
                    target_lines = True
                else:
                    print(line)
            elif [
                truncate_table
                for truncate_table in truncate_data
                if re.match(
                    "^{}\\s\\w+\\.{}\\s".format(pattern_start, truncate_table), line
                )
            ]:
                truncate_lines = True
                target_lines = False
            if target_lines:
                if line.startswith(pattern_start):
                    line = line.replace(";", " (DELIMITER '#');")
                    print(line, end="")
                else:
                    new_line = []
                    for split_line in line.split("\n"):
                        for idx, column in enumerate(split_line.split("\t"), start=1):
                            if idx in [
                                i.column.position
                                for i in personal_data
                                if i.name == table
                            ]:
                                column = get_val(column)
                            elif "#" in column:
                                column = column.replace("#", "-")
                            new_line.append(column)
                        tmp = "#".join(new_line)
                        if tmp.endswith("#"):
                            continue
                        else:
                            print(tmp)
            elif truncate_lines:
                if not line.startswith("COPY"):
                    pass
                else:
                    print(line, end="")
            elif not line.startswith(".", 1):
                print(line, end="")
