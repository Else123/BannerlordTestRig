using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace TestRig.Harness.Logic
{
    /// <summary>
    /// Serializes a <see cref="RunResult"/> to the run-result.json contract (schema 1): fixed field
    /// order, two-space indentation, LF line ends with a trailing LF, invariant numbers, null for
    /// unknown values. The caller encodes the text as UTF-8 without BOM; non-ASCII stays unescaped.
    /// </summary>
    public static class RunResultWriter
    {
        public static string Write(RunResult result)
        {
            if (result == null)
            {
                throw new ArgumentNullException(nameof(result));
            }

            var json = new JsonBuilder();
            json.BeginObject();
            json.Name("schema").Number(RunResult.Schema);
            json.Name("status").String(result.Status.ToString());
            json.Name("reason").String(result.Reason);
            json.Name("seed").Number(result.Seed);
            json.Name("mode").String(result.Mode);
            json.Name("daysRequested").Number(result.DaysRequested);
            json.Name("daysReached").Number(result.DaysReached);
            json.Name("realSeconds").Number(result.RealSeconds);
            json.Name("gameDaysPerRealMinute").TwoDecimals(result.GameDaysPerRealMinute);
            json.Name("playerMapEvents").Number(result.PlayerMapEvents);

            json.Name("modules").BeginArray();
            foreach (ModuleEntry module in result.Modules)
            {
                json.BeginObject();
                json.Name("id").String(module.Id);
                json.Name("version").String(module.Version);
                json.EndObject();
            }

            json.EndArray();

            ExceptionSummary exceptions = result.Exceptions;
            json.Name("exceptions").BeginObject();
            json.Name("total").Number(exceptions.Total);
            json.Name("own").Number(exceptions.Own);
            json.Name("unhandled").Number(exceptions.Unhandled);
            json.Name("top").BeginArray();
            foreach (ExceptionKeyCount entry in exceptions.Top)
            {
                json.BeginObject();
                json.Name("key").String(entry.Key);
                json.Name("count").Number(entry.Count);
                json.EndObject();
            }

            json.EndArray();
            json.EndObject();

            json.Name("scenarios").BeginArray();
            foreach (ScenarioResult scenario in result.Scenarios)
            {
                json.BeginObject();
                json.Name("id").String(scenario.Id);
                json.Name("status").String(scenario.Status.ToString());
                json.Name("seconds").Number(scenario.Seconds);
                json.EndObject();
            }

            json.EndArray();

            json.Name("checks").BeginArray();
            foreach (CheckResult check in result.Checks)
            {
                json.BeginObject();
                json.Name("scenario").String(check.Scenario);
                json.Name("name").String(check.Name);
                json.Name("expected").String(check.Expected);
                json.Name("actual").String(check.Actual);
                json.Name("passed").Bool(check.Passed);
                json.EndObject();
            }

            json.EndArray();
            json.EndObject();
            return json.ToString();
        }

        /// <summary>
        /// Minimal indenting JSON emitter. Each value either follows <see cref="Name"/> (inside an
        /// object) or is an array element; the builder places commas, line breaks and indentation.
        /// Empty containers are written as <c>[]</c> / <c>{}</c>.
        /// </summary>
        private sealed class JsonBuilder
        {
            private readonly StringBuilder _sb = new StringBuilder();

            // One entry per open container: true while it has no element yet.
            private readonly Stack<bool> _isEmpty = new Stack<bool>();

            private bool _afterName;

            public JsonBuilder Name(string name)
            {
                StartElement();
                AppendString(name);
                _sb.Append(": ");
                _afterName = true;
                return this;
            }

            public void BeginObject()
            {
                Open('{');
            }

            public void EndObject()
            {
                Close('}');
            }

            public void BeginArray()
            {
                Open('[');
            }

            public void EndArray()
            {
                Close(']');
            }

            public void String(string value)
            {
                StartValue();
                if (value == null)
                {
                    _sb.Append("null");
                }
                else
                {
                    AppendString(value);
                }
            }

            public void Number(int? value)
            {
                StartValue();
                _sb.Append(value.HasValue ? value.Value.ToString(CultureInfo.InvariantCulture) : "null");
            }

            // "F2" keeps the two-decimal rounding visible ("1.50"), which is a valid JSON number.
            // JSON has no NaN or Infinity: a non-finite value is unknown and written as null.
            public void TwoDecimals(double? value)
            {
                StartValue();
                bool finite = value.HasValue && !double.IsNaN(value.Value) && !double.IsInfinity(value.Value);
                _sb.Append(finite ? value.Value.ToString("F2", CultureInfo.InvariantCulture) : "null");
            }

            public void Bool(bool value)
            {
                StartValue();
                _sb.Append(value ? "true" : "false");
            }

            public override string ToString()
            {
                return _sb.ToString() + "\n";
            }

            private void Open(char bracket)
            {
                StartValue();
                _sb.Append(bracket);
                _isEmpty.Push(true);
            }

            private void Close(char bracket)
            {
                bool wasEmpty = _isEmpty.Pop();
                if (!wasEmpty)
                {
                    NewLine();
                }

                _sb.Append(bracket);
            }

            // A value after a name sits on the name's line; otherwise it is a new array element.
            private void StartValue()
            {
                if (_afterName)
                {
                    _afterName = false;
                    return;
                }

                if (_isEmpty.Count > 0)
                {
                    StartElement();
                }
            }

            private void StartElement()
            {
                if (!_isEmpty.Pop())
                {
                    _sb.Append(',');
                }

                _isEmpty.Push(false);
                NewLine();
            }

            private void NewLine()
            {
                _sb.Append('\n').Append(' ', 2 * _isEmpty.Count);
            }

            private void AppendString(string value)
            {
                _sb.Append('"');
                foreach (char c in value)
                {
                    if (c == '"' || c == '\\')
                    {
                        _sb.Append('\\').Append(c);
                    }
                    else if (c < ' ')
                    {
                        _sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        _sb.Append(c);
                    }
                }

                _sb.Append('"');
            }
        }
    }
}
