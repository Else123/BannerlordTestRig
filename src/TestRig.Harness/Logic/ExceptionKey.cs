namespace TestRig.Harness.Logic
{
    /// <summary>
    /// Builds the string keys that group first-chance exceptions. Engine-free: the caller passes the
    /// exception type name, message and throw site (TargetSite) as plain strings.
    /// </summary>
    public static class ExceptionKey
    {
        /// <summary>Longest message part of a <see cref="Full"/> key; the rest is cut off.</summary>
        public const int MaxMessageLength = 200;

        private const string Unknown = "?";

        /// <summary>
        /// Throw site "&lt;declaring type&gt;.&lt;method&gt;"; "?" when the method is unknown and
        /// "?.&lt;method&gt;" when only the declaring type is.
        /// </summary>
        public static string Site(string declaringTypeFullName, string methodName)
        {
            if (methodName == null)
            {
                return Unknown;
            }

            return (declaringTypeFullName ?? Unknown) + "." + methodName;
        }

        /// <summary>
        /// "&lt;type&gt;: &lt;message&gt; @ &lt;site&gt;" with the message on one line and cut to
        /// <see cref="MaxMessageLength"/> characters. Groups the log budget and the top[] statistics.
        /// </summary>
        public static string Full(string typeFullName, string message, string site)
        {
            string text = message ?? string.Empty;
            if (text.Length > MaxMessageLength)
            {
                text = text.Substring(0, MaxMessageLength);
            }

            return typeFullName + ": " + OneLine(text) + " @ " + site;
        }

        /// <summary>
        /// "&lt;type&gt; @ &lt;site&gt;" without the message: keys the own-assembly classification, so an
        /// exception whose message varies per occurrence ("not found: &lt;id&gt;") costs one stack walk.
        /// </summary>
        public static string Own(string typeFullName, string site)
        {
            return typeFullName + " @ " + site;
        }

        private static string OneLine(string text)
        {
            return text.Replace("\r", " ").Replace("\n", " ");
        }
    }
}
