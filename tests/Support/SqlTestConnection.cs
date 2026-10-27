using System;
using System.Data;
using System.Collections.Generic;

namespace RetentionEngineTests
{
    public sealed class SqlTestConnection : IDisposable
    {
        public bool Opened
        {
            get;
            private set;
        }
        public bool Disposed
        {
            get;
            private set;
        }
        public bool FailOpen
        {
            get;
            set;
        }
        public bool FailCreateCommand
        {
            get;
            set;
        }
        public SqlTestCommand Command
        {
            get;
        }
        = new SqlTestCommand();

        public void Open()
        {
            if (FailOpen)
            {
                throw new InvalidOperationException("Login failed.");
            }
            Opened = true;
        }

        public SqlTestCommand CreateCommand()
        {
            if (FailCreateCommand)
            {
                throw new InvalidOperationException("Cannot create command.");
            }
            return Command;
        }

        public void Dispose()
        {
            Opened = false;
            Disposed = true;
        }
    }

    public sealed class SqlTestParameter
    {
        public string ParameterName
        {
            get;
            set;
        }
        public DbType DbType
        {
            get;
            set;
        }
        public int Size
        {
            get;
            set;
        }
        public object Value
        {
            get;
            set;
        }
    }

    public sealed class SqlTestCommand : IDisposable
    {
        public List<SqlTestParameter> Parameters
        {
            get;
        }
        = new List<SqlTestParameter>();

        public SqlTestParameter CreateParameter()
        {
            return new SqlTestParameter();
        }

        public string CommandText
        {
            get;
            set;
        }
        public int CommandTimeout
        {
            get;
            set;
        }
        public bool Disposed
        {
            get;
            private set;
        }
        public bool FailExecute
        {
            get;
            set;
        }
        public bool FailDispose
        {
            get;
            set;
        }
        public DataTable Table
        {
            get;
        }
        = new DataTable();
        public DataTableReader Reader
        {
            get;
            private set;
        }

        public DataTableReader ExecuteReader()
        {
            if (FailExecute)
            {
                throw new InvalidOperationException("Query failed.");
            }
            Reader = Table.CreateDataReader();
            return Reader;
        }

        public void Dispose()
        {
            Disposed = true;
            if (FailDispose)
            {
                throw new InvalidOperationException("Command disposal failed.");
            }
        }
    }
}
