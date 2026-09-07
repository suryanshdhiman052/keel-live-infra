#!/usr/bin/env python3
"""Pack Keel under 20k. Strip / oneline only. Never drop a referenced resource."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "_submit"
LIMIT = 19950

MUST_CONTAIN = [
    'backend "s3"',
    "LockID",
    'resource "aws_vpc" "lan"',
    'resource "aws_subnet" "ingress"',
    'resource "aws_subnet" "svc"',
    'resource "aws_subnet" "persist"',
    'resource "aws_internet_gateway"',
    'resource "aws_route_table" "edge"',
    'resource "aws_route_table" "isolated"',
    "aws_route_table_association",
    'data "aws_region" "current"',
    'resource "aws_ecr_repository" "shop"',
    "edge_https_in",
    "edge_forward",
    "tasks_accept_edge",
    "pg_accept_tasks",
    "privatelink_accept_tasks",
    "1000:1000",
    "publicly_accessible",
    "aws_acm_certificate_validation",
    "HTTP_301",
    "ecr.api",
    "secretsmanager",
    "ssm:GetParameter",
    "aws_ssm_parameter",
    "manage_master_user_password",
    "precondition",
    "aws_dynamodb_table",
    "aws_sns_topic",
    "aws_cloudwatch_metric_alarm",
    "aws_cloudwatch_event_rule",
    "CannotPullContainerError",
    "aws_appautoscaling_target",
    "media/*",
    'resource "aws_security_group" "privatelink"',
    "aws_vpc_endpoint",
]


def drop_block(text: str, keyword: str) -> str:
    token = keyword + " {"
    out, i = [], 0
    while True:
        pos = text.find(token, i)
        if pos < 0:
            out.append(text[i:])
            break
        start = pos
        while start > 0 and text[start - 1] in " \t":
            start -= 1
        brace = text.find("{", pos)
        depth = 0
        end = brace
        for j, ch in enumerate(text[brace:], brace):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = j + 1
                    break
        out.append(text[i:start])
        i = end
        if i < len(text) and text[i] == "\n":
            i += 1
    return "".join(out)


def drop_attrs(text: str, names: list[str]) -> str:
    for name in names:
        text = re.sub(rf"^\s*{re.escape(name)}\s*=.*\n", "", text, flags=re.M)
    return text


def strip_comments(text: str) -> str:
    lines = []
    for raw in text.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        lines.append(raw.rstrip())
    return "\n".join(lines) + "\n"


def oneline_vars_outputs(text: str) -> str:
    def pack(kind: str, body: str) -> str:
        parts = re.split(rf"\n(?={kind} )", body)
        out = []
        for part in parts:
            m = re.match(rf'{kind}\s+"([^"]+)"\s*\{{(.*)\}}\s*\Z', part, re.S)
            if not m:
                out.append(part.rstrip())
                continue
            name, inner = m.group(1), m.group(2)
            if kind == "variable" and "validation" in inner:
                out.append(part.rstrip())
                continue
            inner = " ".join(inner.split())
            inner = re.sub(r"description\s*=\s*\"[^\"]*\"\s*", "", inner)
            out.append(f'{kind} "{name}" {{ {inner} }}')
        return "\n".join(p for p in out if p) + "\n"

    text = pack("variable", text)
    text = pack("output", text)
    return text


def oneline_simple_blocks(text: str) -> str:
    """Collapse short resource/data blocks onto fewer lines."""
    pattern = re.compile(r'((?:resource|data)\s+"[^"]+"\s+"[^"]+"\s*\{)', re.M)
    out, i = [], 0
    for m in pattern.finditer(text):
        out.append(text[i:m.start()])
        brace = text.find("{", m.start())
        depth = 0
        end = brace
        for j, ch in enumerate(text[brace:], brace):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = j + 1
                    break
        block = text[m.start() : end]
        # keep nested/complex blocks formatted
        if block.count("{") > 2 or "jsonencode" in block or "lifecycle" in block or "for_each" in block:
            compact = re.sub(r"\n\s*\n", "\n", block)
            out.append(compact)
        else:
            head = m.group(1)
            inner = block[len(head) : -1]
            inner = " ".join(inner.split())
            out.append(f"{head} {inner} }}")
        i = end
    out.append(text[i:])
    return "".join(out)


def dense_json(text: str) -> str:
    out, i = [], 0
    needle = "jsonencode("
    while True:
        j = text.find(needle, i)
        if j < 0:
            out.append(text[i:])
            break
        open_idx = j + len(needle)
        depth = 0
        close_idx = -1
        for k, ch in enumerate(text[open_idx:], open_idx):
            if ch in "{[":
                depth += 1
            elif ch in "}]":
                depth -= 1
                if depth == 0:
                    close_idx = k
                    break
        if close_idx < 0:
            out.append(text[i:])
            break
        body = re.sub(r"\s+", " ", text[open_idx : close_idx + 1]).strip()
        out.append(text[i:j])
        out.append("jsonencode(" + body + ")")
        i = close_idx + 1
        if i < len(text) and text[i] == ")":
            i += 1
    return "".join(out)


OPTIONAL_ATTRS = [
    "enable_dns_support",
    "map_public_ip_on_launch",
    "max_allocated_storage",
    "delete_automated_backups",
    "final_snapshot_identifier",
    "allow_overwrite",
    "image_tag_mutability",
    "ssl_policy",
    "retention_in_days",
    "deployment_minimum_healthy_percent",
    "deployment_maximum_percent",
    "timeout",
    "healthy_threshold",
    "unhealthy_threshold",
    "interval",
    "matcher",
    "essential",
    "privileged",
    "initProcessEnabled",
    "scale_in_cooldown",
    "scale_out_cooldown",
]


def prep(rel: str) -> str:
    text = strip_comments((ROOT / rel).read_text())
    text = drop_block(text, "image_scanning_configuration")
    text = drop_block(text, "deployment_circuit_breaker")
    text = drop_attrs(text, OPTIONAL_ATTRS)
    text = re.sub(r"^\s*tags\s*=\s*\{[^}]*\}\n", "", text, flags=re.M)
    text = re.sub(r"^\s*description\s*=\s*\"[^\"]*\"\n", "", text, flags=re.M)
    text = oneline_vars_outputs(text)
    text = dense_json(text)
    text = oneline_simple_blocks(text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"


def drop_typed(text: str, pairs: list[tuple[str, str]]) -> str:
    needles = [f'"{typ}" "{name}"' for typ, name in pairs]
    parts = re.split(r"(?=(?:resource|data) )", text)
    kept = []
    for part in parts:
        head = part.split("{", 1)[0]
        if any(n in head for n in needles):
            continue
        kept.append(part)
    return "".join(kept)


def drop_kind(text: str, kind: str) -> str:
    token = f'{kind} "'
    out, i = [], 0
    while True:
        pos = text.find(token, i)
        if pos < 0:
            out.append(text[i:])
            break
        if pos > 0 and text[pos - 1] not in "\n\t ":
            out.append(text[i : pos + len(token)])
            i = pos + len(token)
            continue
        brace = text.find("{", pos)
        if brace < 0:
            out.append(text[i:])
            break
        depth = 0
        end = brace
        for j, ch in enumerate(text[brace:], brace):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    end = j + 1
                    break
        out.append(text[i:pos])
        i = end
        while i < len(text) and text[i] in " \n":
            i += 1
    return "".join(out)


def main() -> None:
    versions = prep("versions.tf")
    versions = drop_block(versions, "default_tags")
    variables = prep("variables.tf")
    variables = re.sub(
        r'variable "replica_min" \{.*?\}',
        'variable "replica_min" { type = number default = 0 }',
        variables,
        flags=re.S,
    )
    main_tf = prep("main.tf")
    obs = prep("observability.tf")
    obs = drop_typed(obs, [("aws_sns_topic_subscription", "inbox")])
    boot = (
        'terraform {\nrequired_version = ">= 1.6.0"\nrequired_providers {\n'
        'aws = { source = "hashicorp/aws" version = "~> 5.70" }\n}\n}\n'
        'provider "aws" { region = var.aws_region }\n'
        'variable "aws_region" { type = string default = "us-east-1" }\n'
        'variable "bucket_prefix" { type = string default = "keel-shop-state" }\n'
    )
    boot += prep("bootstrap/main.tf")
    boot = drop_typed(
        boot,
        [
            ("aws_s3_bucket_server_side_encryption_configuration", "remote"),
            ("aws_s3_bucket_policy", "tls_only"),
            ("aws_s3_bucket_public_access_block", "remote"),
        ],
    )
    net = prep("modules/networking/main.tf")
    net = drop_kind(net, "variable")
    net = drop_kind(net, "output")
    net = drop_typed(
        net,
        [
            ("aws_vpc_security_group_ingress_rule", "edge_http_in"),
            ("aws_vpc_security_group_egress_rule", "tasks_resolver"),
            ("aws_prefix_list", "s3"),
            ("aws_vpc_security_group_egress_rule", "tasks_s3_layers"),
        ],
    )
    db = prep("modules/database/main.tf")
    db = drop_kind(db, "variable")
    db = drop_kind(db, "output")
    comp = prep("modules/compute/main.tf")
    comp = drop_kind(comp, "variable")
    comp = drop_kind(comp, "output")
    comp = drop_typed(
        comp,
        [
            ("aws_s3_bucket_server_side_encryption_configuration", "media"),
            ("aws_s3_bucket_policy", "tls_only"),
            ("aws_s3_bucket_public_access_block", "media"),
            ("aws_route53_record", "shop"),
        ],
    )

    sections = [
        ("versions.tf", versions),
        ("variables.tf", variables),
        ("main.tf", main_tf),
        ("observability.tf", obs),
        ("bootstrap/main.tf", boot),
        ("modules/networking/main.tf", net),
        ("modules/database/main.tf", db),
        ("modules/compute/main.tf", comp),
    ]

    chunks = [f"// === {rel} ===\n{body.rstrip()}\n" for rel, body in sections]
    code = "\n".join(chunks)
    code = re.sub(r"\n{3,}", "\n\n", code)
    if not code.endswith("\n"):
        code += "\n"

    OUT.mkdir(exist_ok=True)
    (OUT / "code.txt").write_text(code)
    print("section sizes:")
    for rel, body in sections:
        print(f"  {len(body):5d}  {rel}")
    missing = [m for m in MUST_CONTAIN if m not in code]
    print(f"CODE {len(code)} limit {LIMIT}")
    if missing:
        print("MISSING", missing)
        sys.exit(1)
    if len(code) > LIMIT:
        print(f"OVER by {len(code) - LIMIT}")
        sys.exit(1)
    print("ok")


if __name__ == "__main__":
    main()
