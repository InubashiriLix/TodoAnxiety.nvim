//! TodoAnxiety.nvim local Rust core.
//!
//! The Neovim plugin requires this process. It speaks MessagePack-RPC over
//! stdin/stdout (`jobstart(..., { rpc = true })`) so the Lua UI can make
//! synchronous calls with `vim.rpcrequest` without FFI or ABI coupling.

use chrono::{Datelike, Duration as ChronoDuration, Local, NaiveDateTime, TimeZone};
use rmpv::Value;
use std::collections::HashMap;
use std::io::{self, Write};
use std::time::{SystemTime, UNIX_EPOCH};

const PROTOCOL: i64 = 1;

fn now_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn map_get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Map(entries) => entries.iter().find_map(|(k, v)| {
            if k.as_str() == Some(key) {
                Some(v)
            } else {
                None
            }
        }),
        _ => None,
    }
}

fn as_str(value: &Value) -> Option<&str> {
    value.as_str()
}

fn as_i64(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| value.as_u64().map(|v| v as i64))
}

fn map_string(value: &Value, key: &str) -> Option<String> {
    map_get(value, key).and_then(as_str).map(ToString::to_string)
}

fn map_i64(value: &Value, key: &str) -> Option<i64> {
    map_get(value, key).and_then(as_i64)
}

fn map_array<'a>(value: &'a Value, key: &str) -> Option<&'a Vec<Value>> {
    map_get(value, key).and_then(|v| v.as_array())
}

fn map_bool(value: &Value, key: &str) -> Option<bool> {
    map_get(value, key).and_then(|v| v.as_bool())
}

static DB: std::sync::OnceLock<std::sync::Mutex<HashMap<String, rusqlite::Connection>>> =
    std::sync::OnceLock::new();

fn db_slot() -> &'static std::sync::Mutex<HashMap<String, rusqlite::Connection>> {
    DB.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

fn opt_i64(row: &rusqlite::Row<'_>, name: &str) -> Option<i64> {
    row.get::<_, Option<i64>>(name).ok().flatten()
}

fn opt_string(row: &rusqlite::Row<'_>, name: &str) -> Option<String> {
    row.get::<_, Option<String>>(name).ok().flatten()
}

fn tags_value(conn: &rusqlite::Connection, task_id: i64) -> Value {
    let mut statement = match conn.prepare(
        "SELECT tags.name FROM tags JOIN task_tags ON task_tags.tag_id=tags.id \
         WHERE task_tags.task_id=? ORDER BY lower(tags.name), tags.name",
    ) {
        Ok(value) => value,
        Err(_) => return Value::Array(vec![]),
    };
    let rows = statement
        .query_map([task_id], |row| row.get::<_, String>(0))
        .ok()
        .map(|rows| rows.filter_map(Result::ok).map(Value::from).collect())
        .unwrap_or_default();
    Value::Array(rows)
}

fn reminder_value(conn: &rusqlite::Connection, task_id: i64) -> Option<Value> {
    let mut statement = conn
        .prepare("SELECT * FROM reminders WHERE task_id=?")
        .ok()?;
    let row = statement
        .query_row([task_id], |row| {
            let recurrence_type: String = row.get("recurrence_type")?;
            let recurrence_every: i64 = row.get("recurrence_every")?;
            let recurrence_unit: Option<String> = row.get("recurrence_unit")?;
            let weekdays: String = row.get("weekdays")?;
            let weekdays_value: Vec<Value> = weekdays
                .split(',')
                .filter_map(|value| value.trim().parse::<i64>().ok())
                .map(Value::from)
                .collect();
            let mut entries = vec![
                (Value::from("enabled"), Value::from(row.get::<_, i64>("enabled")? == 1)),
                (
                    Value::from("repeat_interval_seconds"),
                    Value::from(row.get::<_, i64>("repeat_interval_seconds")?),
                ),
                (
                    Value::from("scheduled_at"),
                    Value::from(row.get::<_, i64>("scheduled_at")?),
                ),
                (
                    Value::from("next_reminder_at"),
                    Value::from(row.get::<_, i64>("next_reminder_at")?),
                ),
                (
                    Value::from("occurrence_started_at"),
                    Value::from(row.get::<_, i64>("occurrence_started_at")?),
                ),
                (
                    Value::from("recurrence"),
                    Value::Map(vec![
                        (Value::from("kind"), Value::from(recurrence_type)),
                        (Value::from("every"), Value::from(recurrence_every)),
                        (
                            Value::from("unit"),
                            recurrence_unit.map(Value::from).unwrap_or(Value::Nil),
                        ),
                        (Value::from("weekdays"), Value::Array(weekdays_value)),
                    ]),
                ),
            ];
            for key in ["snoozed_until", "last_reminded_at"] {
                if let Some(value) = opt_i64(row, key) {
                    entries.push((Value::from(key), Value::from(value)));
                }
            }
            Ok(Value::Map(entries))
        })
        .ok()?;
    Some(row)
}

fn task_value(conn: &rusqlite::Connection, row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    let id = row.get::<_, i64>("id")?;
    let mut entries = vec![
        (Value::from("id"), Value::from(id)),
        (Value::from("title"), Value::from(row.get::<_, String>("title")?)),
        (
            Value::from("description"),
            Value::from(row.get::<_, String>("description")?),
        ),
        (Value::from("status"), Value::from(row.get::<_, String>("status")?)),
        (Value::from("priority"), Value::from(row.get::<_, i64>("priority")?)),
        (
            Value::from("created_at"),
            Value::from(row.get::<_, i64>("created_at")?),
        ),
        (
            Value::from("updated_at"),
            Value::from(row.get::<_, i64>("updated_at")?),
        ),
        (
            Value::from("kind"),
            Value::from(row.get::<_, String>("kind").unwrap_or_else(|_| "task".to_string())),
        ),
        (Value::from("tags"), tags_value(conn, id)),
    ];
    for key in ["due_date", "due_time", "sync_uuid", "sync_revision"] {
        if let Some(value) = opt_string(row, key) {
            entries.push((Value::from(key), Value::from(value)));
        }
    }
    for key in ["completed_at", "archived_at"] {
        if let Some(value) = opt_i64(row, key) {
            entries.push((Value::from(key), Value::from(value)));
        }
    }
    if let Some(reminder) = reminder_value(conn, id) {
        entries.push((Value::from("reminder"), reminder));
    }
    Ok(Value::Map(entries))
}

fn tasks_list(params: &[Value]) -> Value {
    let slot = db_slot();
    let guard = match slot.lock() {
        Ok(value) => value,
        Err(_) => return error("database lock poisoned"),
    };
    let options = params.first().cloned().unwrap_or(Value::Nil);
    let Some(path) = map_string(&options, "path") else {
        return error("database path required");
    };
    let Some(conn) = guard.get(&path) else {
        return error("database is not open");
    };
    let archived = map_bool(&options, "archived").unwrap_or(false);
    let mut sql = String::from(
        "SELECT * FROM tasks WHERE archived_at IS ",
    );
    sql.push_str(if archived { "NOT NULL" } else { "NULL" });
    let kind = map_string(&options, "kind");
    if kind.is_some() {
        sql.push_str(" AND kind=?");
    }
    sql.push_str(" ORDER BY created_at, id");
    let mut statement = match conn.prepare(&sql) {
        Ok(value) => value,
        Err(err) => return error(err.to_string()),
    };
    let mapped = if let Some(kind) = kind {
        statement
            .query_map(rusqlite::params![kind], |row| task_value(conn, row))
            .and_then(|rows| rows.collect::<rusqlite::Result<Vec<_>>>())
    } else {
        statement
            .query_map([], |row| task_value(conn, row))
            .and_then(|rows| rows.collect::<rusqlite::Result<Vec<_>>>())
    };
    match mapped {
        Ok(rows) => reply(true, Value::Array(rows)),
        Err(err) => error(err.to_string()),
    }
}

fn task_get(params: &[Value]) -> Value {
    let options = params.first().cloned().unwrap_or(Value::Nil);
    let Some(id) = map_i64(&options, "id") else {
        return error("task id required");
    };
    let Some(path) = map_string(&options, "path") else {
        return error("database path required");
    };
    let slot = db_slot();
    let guard = match slot.lock() {
        Ok(value) => value,
        Err(_) => return error("database lock poisoned"),
    };
    let Some(conn) = guard.get(&path) else {
        return error("database is not open");
    };
    let mut statement = match conn.prepare("SELECT * FROM tasks WHERE id=?") {
        Ok(value) => value,
        Err(err) => return error(err.to_string()),
    };
    match statement.query_row([id], |row| task_value(conn, row)) {
        Ok(value) => reply(true, value),
        Err(rusqlite::Error::QueryReturnedNoRows) => reply(true, Value::Nil),
        Err(err) => error(err.to_string()),
    }
}

fn db_open(params: &[Value]) -> Value {
    let options = params.first().cloned().unwrap_or(Value::Nil);
    let Some(path) = map_string(&options, "path") else {
        return error("database path required");
    };
    let connection = match rusqlite::Connection::open(&path) {
        Ok(value) => value,
        Err(err) => return error(err.to_string()),
    };
    let _ = connection.execute("PRAGMA foreign_keys=ON", []);
    let _ = connection.execute("PRAGMA journal_mode=WAL", []);
    let _ = connection.execute("PRAGMA busy_timeout=3000", []);
    let slot = db_slot();
    match slot.lock() {
        Ok(mut guard) => {
            guard.insert(path.clone(), connection);
            reply(
                true,
                Value::Map(vec![
                    (Value::from("path"), Value::from(path)),
                    (Value::from("open"), Value::from(true)),
                ]),
            )
        }
        Err(_) => error("database lock poisoned"),
    }
}

fn db_close(params: &[Value]) -> Value {
    if let Ok(mut guard) = db_slot().lock() {
        if let Some(path) = params.first().and_then(as_str) {
            guard.remove(path);
        } else {
            guard.clear();
        }
    }
    reply(true, Value::from(true))
}

fn reply(ok: bool, value: Value) -> Value {
    Value::Map(vec![
        (Value::from("ok"), Value::from(ok)),
        (Value::from("value"), value),
    ])
}

fn error(message: impl Into<String>) -> Value {
    Value::Map(vec![
        (Value::from("ok"), Value::from(false)),
        (Value::from("error"), Value::from(message.into())),
    ])
}

fn parse_deadline(task: &Value) -> Option<i64> {
    let date = map_string(task, "due_date")?;
    let time = map_string(task, "due_time");
    let text = match time {
        Some(time) if !time.is_empty() => format!("{} {}", date, time),
        _ => format!("{} 23:59:59", date),
    };
    let formats = ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"];
    for format in formats {
        if let Ok(naive) = NaiveDateTime::parse_from_str(&text, format) {
            if let Some(local) = Local.from_local_datetime(&naive).single() {
                return Some(local.timestamp());
            }
        }
    }
    None
}

fn urgency(task: &Value, now: i64) -> Value {
    let due = parse_deadline(task);
    let remaining = due.map(|epoch| epoch - now);
    let (base, reason) = match remaining {
        Some(value) if value < 0 => (120, "overdue"),
        Some(value) if value <= 86_400 => (80, "due_today"),
        Some(value) if value <= 259_200 => (60, "due_in_days"),
        Some(value) if value <= 604_800 => (40, "due_in_days"),
        Some(_) => (20, "due_later"),
        None => (0, "no_deadline"),
    };
    let priority = map_i64(task, "priority").unwrap_or(3);
    let bonus = match priority {
        0 => 30,
        1 => 20,
        2 => 10,
        _ => 0,
    };
    let score = base + bonus;
    let level = if reason == "overdue" {
        "overdue"
    } else if due.is_none() {
        "priority_only"
    } else if score >= 80 {
        "urgent"
    } else if score >= 60 {
        "high"
    } else {
        "attention"
    };
    let days = remaining.map(|value| {
        let value = value.max(0) as f64 / 86_400.0;
        value.ceil() as i64
    });
    let mut entries = vec![
        (Value::from("score"), Value::from(score)),
        (Value::from("level"), Value::from(level)),
        (Value::from("reason"), Value::from(reason)),
    ];
    if let Some(epoch) = due {
        entries.push((Value::from("due_epoch"), Value::from(epoch)));
    }
    if let Some(days) = days {
        entries.push((Value::from("days"), Value::from(days)));
    }
    Value::Map(entries)
}

#[derive(Clone, Debug)]
struct Rule {
    kind: String,
    every: i64,
    unit: Option<String>,
    weekdays: Vec<i64>,
}

fn normalize_rule(value: &Value) -> Result<Rule, String> {
    let kind = map_string(value, "kind")
        .or_else(|| map_string(value, "recurrence_type"))
        .unwrap_or_else(|| "once".to_string());
    if !matches!(
        kind.as_str(),
        "once" | "daily" | "weekdays" | "weekly" | "interval"
    ) {
        return Err("invalid_kind".to_string());
    }
    let every = map_i64(value, "every")
        .or_else(|| map_i64(value, "recurrence_every"))
        .unwrap_or(1);
    if every < 1 {
        return Err("invalid_every".to_string());
    }
    let unit = map_string(value, "unit").or_else(|| map_string(value, "recurrence_unit"));
    if kind == "interval" {
        match unit.as_deref() {
            Some("minutes") | Some("hours") | Some("days") => {}
            _ => return Err("invalid_unit".to_string()),
        }
    }
    let mut weekdays: Vec<i64> = map_array(value, "weekdays")
        .map(|items| {
            items
                .iter()
                .filter_map(as_i64)
                .filter(|day| (1..=7).contains(day))
                .collect()
        })
        .unwrap_or_default();
    weekdays.sort_unstable();
    weekdays.dedup();
    if kind == "weekly" && weekdays.is_empty() {
        return Err("weekdays_required".to_string());
    }
    Ok(Rule {
        kind,
        every,
        unit,
        weekdays,
    })
}

fn local_naive(epoch: i64) -> Option<NaiveDateTime> {
    Local
        .timestamp_opt(epoch, 0)
        .single()
        .map(|value| value.naive_local())
}

fn calendar_days(epoch: i64, days: i64) -> Option<i64> {
    let naive = local_naive(epoch)?;
    let next = naive.checked_add_signed(ChronoDuration::days(days))?;
    Local.from_local_datetime(&next).single().map(|value| value.timestamp())
}

fn weekday_lua(epoch: i64) -> Option<i64> {
    Local
        .timestamp_opt(epoch, 0)
        .single()
        .map(|value| value.weekday().num_days_from_sunday() as i64 + 1)
}

fn recurrence_next(rule: &Rule, scheduled_at: i64, now: i64) -> Option<i64> {
    match rule.kind.as_str() {
        "once" => None,
        "interval" => {
            let unit = rule.unit.as_deref().unwrap_or("minutes");
            if unit == "days" {
                let mut next = scheduled_at;
                loop {
                    next = calendar_days(next, rule.every)?;
                    if next > now {
                        return Some(next);
                    }
                }
            }
            let step = rule.every
                * match unit {
                    "minutes" => 60,
                    "hours" => 3_600,
                    _ => 86_400,
                };
            let elapsed = (now - scheduled_at).max(0);
            Some(scheduled_at + (elapsed / step + 1) * step)
        }
        "daily" => {
            let mut next = scheduled_at;
            loop {
                next = calendar_days(next, rule.every)?;
                if next > now {
                    return Some(next);
                }
            }
        }
        _ => {
            let allowed: Vec<i64> = if rule.kind == "weekdays" {
                vec![2, 3, 4, 5, 6]
            } else {
                rule.weekdays.clone()
            };
            let mut next = scheduled_at;
            loop {
                next = calendar_days(next, 1)?;
                if next > now && weekday_lua(next).map(|day| allowed.contains(&day)).unwrap_or(false) {
                    return Some(next);
                }
            }
        }
    }
}

fn duration_parse(value: &Value) -> Option<i64> {
    if let Some(number) = as_i64(value) {
        return (number > 0).then_some(number);
    }
    let text = as_str(value)?.trim().to_lowercase().replace(char::is_whitespace, "");
    if text.is_empty() {
        return None;
    }
    let mut total: i64 = 0;
    let mut rebuilt = String::new();
    let mut digits = String::new();
    for ch in text.chars() {
        if ch.is_ascii_digit() {
            digits.push(ch);
            continue;
        }
        let amount: i64 = digits.parse().ok()?;
        digits.clear();
        let unit = match ch {
            's' => 1,
            'm' => 60,
            'h' => 3_600,
            'd' => 86_400,
            _ => return None,
        };
        total = total.checked_add(amount.checked_mul(unit)?)?;
        rebuilt.push_str(&amount.to_string());
        rebuilt.push(ch);
    }
    if !digits.is_empty() || rebuilt != text || total <= 0 {
        return None;
    }
    Some(total)
}

fn rule_value(rule: &Rule) -> Value {
    let mut entries = vec![
        (Value::from("kind"), Value::from(rule.kind.clone())),
        (Value::from("every"), Value::from(rule.every)),
        (
            Value::from("weekdays"),
            Value::Array(rule.weekdays.iter().map(|day| Value::from(*day)).collect()),
        ),
    ];
    if let Some(unit) = &rule.unit {
        entries.push((Value::from("unit"), Value::from(unit.clone())));
    }
    Value::Map(entries)
}

fn handle(method: &str, params: &[Value]) -> Value {
    match method {
        "core.db_open" => db_open(params),
        "core.db_close" => db_close(params),
        "core.tasks_list" => tasks_list(params),
        "core.tasks_get" => task_get(params),
        "core.hello" => reply(
            true,
            Value::Map(vec![
                (Value::from("name"), Value::from("todo-core")),
                (
                    Value::from("version"),
                    Value::from(env!("CARGO_PKG_VERSION")),
                ),
                (Value::from("protocol"), Value::from(PROTOCOL)),
                (Value::from("pid"), Value::from(std::process::id() as i64)),
            ]),
        ),
        "core.health" => reply(
            true,
            Value::Map(vec![
                (Value::from("version"), Value::from(env!("CARGO_PKG_VERSION"))),
                (Value::from("protocol"), Value::from(PROTOCOL)),
                (Value::from("now"), Value::from(now_epoch())),
            ]),
        ),
        "core.urgency" => {
            let task = params.first().cloned().unwrap_or(Value::Nil);
            let now = params.get(1).and_then(as_i64).unwrap_or_else(now_epoch);
            reply(true, urgency(&task, now))
        }
        "core.urgency_batch" => {
            let tasks = params
                .first()
                .and_then(|value| value.as_array())
                .cloned()
                .unwrap_or_default();
            let now = params.get(1).and_then(as_i64).unwrap_or_else(now_epoch);
            reply(
                true,
                Value::Array(tasks.iter().map(|task| urgency(task, now)).collect()),
            )
        }
        "core.recurrence_normalize" => {
            let value = params.first().cloned().unwrap_or(Value::Nil);
            match normalize_rule(&value) {
                Ok(rule) => reply(true, rule_value(&rule)),
                Err(message) => error(message),
            }
        }
        "core.recurrence_next" => {
            let value = params.first().cloned().unwrap_or(Value::Nil);
            let scheduled_at = params.get(1).and_then(as_i64).unwrap_or(0);
            let now = params.get(2).and_then(as_i64).unwrap_or_else(now_epoch);
            match normalize_rule(&value) {
                Ok(rule) => reply(
                    true,
                    recurrence_next(&rule, scheduled_at, now)
                        .map(Value::from)
                        .unwrap_or(Value::Nil),
                ),
                Err(message) => error(message),
            }
        }
        "core.duration_parse" => {
            let value = params.first().cloned().unwrap_or(Value::Nil);
            reply(
                true,
                duration_parse(&value).map(Value::from).unwrap_or(Value::Nil),
            )
        }
        "core.shutdown" => reply(true, Value::from(true)),
        other => error(format!("unknown method: {}", other)),
    }
}

fn main() {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = stdout.lock();
    loop {
        let request = match rmpv::decode::read_value(&mut reader) {
            Ok(value) => value,
            Err(_) => break,
        };
        let Some(items) = request.as_array() else {
            continue;
        };
        let kind = items.first().and_then(as_i64).unwrap_or(-1);
        if kind == 2 {
            // Notification: no response.
            if let Some(method) = items.get(1).and_then(as_str) {
                if method == "core.shutdown" {
                    break;
                }
            }
            continue;
        }
        if kind != 0 {
            continue;
        }
        let message_id = items.get(1).cloned().unwrap_or(Value::Nil);
        let method = items.get(2).and_then(as_str).unwrap_or("");
        let params = items
            .get(3)
            .and_then(|value| value.as_array())
            .cloned()
            .unwrap_or_default();
        let value = handle(method, &params);
        let shutdown = method == "core.shutdown";
        let response = Value::Array(vec![
            Value::from(1),
            message_id,
            Value::Nil,
            value,
        ]);
        if rmpv::encode::write_value(&mut writer, &response).is_err() {
            break;
        }
        if writer.flush().is_err() || shutdown {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(entries: Vec<(&str, Value)>) -> Value {
        Value::Map(
            entries
                .into_iter()
                .map(|(key, value)| (Value::from(key), value))
                .collect(),
        )
    }

    #[test]
    fn duration_keeps_compact_units_only() {
        assert_eq!(duration_parse(&Value::from("1h 30m")), Some(5400));
        assert_eq!(duration_parse(&Value::from("90m")), Some(5400));
        assert_eq!(duration_parse(&Value::from("1x")), None);
        assert_eq!(duration_parse(&Value::from("1h 30")), None);
    }

    #[test]
    fn recurrence_normalizes_weekdays_and_next_daily() {
        let rule = normalize_rule(&map(vec![
            ("kind", Value::from("weekly")),
            ("weekdays", Value::Array(vec![Value::from(3), Value::from(1), Value::from(3)])),
        ]))
        .unwrap();
        assert_eq!(rule.weekdays, vec![1, 3]);
        let next = recurrence_next(&rule, 1_700_000_000, 1_700_000_000);
        assert!(next.is_some());
    }

    #[test]
    fn overdue_priority_combines() {
        let task = map(vec![
            ("priority", Value::from(0)),
            ("due_date", Value::from("2020-01-01")),
        ]);
        let value = urgency(&task, 1_700_000_000);
        assert_eq!(map_string(&value, "level").as_deref(), Some("overdue"));
        assert_eq!(map_i64(&value, "score"), Some(150));
    }
}

