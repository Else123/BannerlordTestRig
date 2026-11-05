using System.Reflection;

namespace TestRig.Harness.Logic
{
    /// <summary>
    /// Sets a private instance field by name through reflection, for game internals that have no
    /// public switch. Never throws: a field that is missing or not a bool (a game update renamed
    /// or retyped it) is reported as failure so the caller can log it and carry on.
    /// </summary>
    public static class PrivateField
    {
        /// <returns>True when the field exists on the target's type (or a base type), is a bool and was set.</returns>
        public static bool TrySetBool(object target, string fieldName, bool value)
        {
            if (target == null || string.IsNullOrEmpty(fieldName))
            {
                return false;
            }

            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;
            for (var type = target.GetType(); type != null; type = type.BaseType)
            {
                FieldInfo field = type.GetField(fieldName, flags | BindingFlags.DeclaredOnly);
                if (field == null)
                {
                    continue;
                }

                if (field.FieldType != typeof(bool))
                {
                    return false;
                }

                field.SetValue(target, value);
                return true;
            }

            return false;
        }
    }
}
