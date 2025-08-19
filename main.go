package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/robfig/cron/v3"
)

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func timestampedPrint(prefix, message string) {
	timestamp := time.Now().Format("2006-01-02 15:04:05")
	fmt.Printf("[%s] %s: %s", timestamp, prefix, message)
}

func streamOutput(prefix string, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	// aumenta limite padrão (64KB) para linhas longas
	const maxLine = 1024 * 1024 // 1MB
	buf := make([]byte, 64*1024)
	scanner.Buffer(buf, maxLine)

	for scanner.Scan() {
		timestampedPrint(prefix, scanner.Text()+"\n")
	}
	if err := scanner.Err(); err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Error reading output: %v\n", err))
	}
}

// parser único para validar e para o cron
func makeParser(withSeconds bool) cron.Parser {
	fields := cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor
	if withSeconds {
		fields |= cron.Second
	}
	return cron.NewParser(fields)
}

func validateSchedule(parser cron.Parser, schedule string) error {
	// @every <duration> é suportado pelo cron, mas validamos explicitamente também
	if strings.HasPrefix(schedule, "@every ") {
		_, err := time.ParseDuration(strings.TrimPrefix(schedule, "@every "))
		return err
	}
	_, err := parser.Parse(schedule)
	return err
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: go-cron <schedule> <command> [args...]")
		os.Exit(1)
	}

	schedule := os.Args[1]
	command := os.Args[2]
	args := os.Args[3:]

	// Config via env
	withSeconds := strings.EqualFold(getenv("CRON_WITH_SECONDS", "false"), "true")
	timeoutStr := getenv("CRON_TIMEOUT", "1h")
	tzName := getenv("TZ", "") // vazio = local do sistema

	timeout, err := time.ParseDuration(timeoutStr)
	if err != nil {
		timestampedPrint("WARN", fmt.Sprintf("Invalid CRON_TIMEOUT=%q, falling back to 1h\n", timeoutStr))
		timeout = time.Hour
	}

	// Timezone
	var loc *time.Location
	if tzName == "" {
		loc = time.Local
	} else {
		loc, err = time.LoadLocation(tzName)
		if err != nil {
			timestampedPrint("WARN", fmt.Sprintf("Invalid TZ=%q, using local time\n", tzName))
			loc = time.Local
		}
	}

	// Parser e validação
	parser := makeParser(withSeconds)
	if err := validateSchedule(parser, schedule); err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Invalid schedule format: %v\n", err))
		os.Exit(1)
	}

	// Checa comando
	if _, err := exec.LookPath(command); err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Command not found: %s\n", command))
		os.Exit(1)
	}

	// Cron configurado com o MESMO parser + recover + timezone
	c := cron.New(
		cron.WithParser(parser),
		cron.WithLocation(loc),
		cron.WithChain(cron.Recover(cron.DefaultLogger)),
	)

	_, err = c.AddFunc(schedule, func() {
		timestampedPrint("INFO", fmt.Sprintf("Executing: %s %s\n", command, strings.Join(args, " ")))

		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()

		cmd := exec.CommandContext(ctx, command, args...)

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			timestampedPrint("ERROR", fmt.Sprintf("stdout pipe: %v\n", err))
			return
		}
		stderr, err := cmd.StderrPipe()
		if err != nil {
			timestampedPrint("ERROR", fmt.Sprintf("stderr pipe: %v\n", err))
			return
		}

		if err := cmd.Start(); err != nil {
			timestampedPrint("ERROR", fmt.Sprintf("start: %v\n", err))
			return
		}

		done := make(chan struct{}, 1)
		go func() { streamOutput("STDOUT", stdout); done <- struct{}{} }()
		go streamOutput("STDERR", stderr)

		// aguarda término
		err = cmd.Wait()
		<-done // garante flush do stdout

		if err != nil {
			if ctx.Err() == context.DeadlineExceeded {
				timestampedPrint("ERROR", fmt.Sprintf("Command timed out after %s\n", timeout))
			} else {
				timestampedPrint("ERROR", fmt.Sprintf("Command finished with error: %v\n", err))
			}
		} else {
			timestampedPrint("INFO", "Command finished successfully\n")
		}
	})
	if err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Error adding cron job: %v\n", err))
		os.Exit(1)
	}

	timestampedPrint("INFO", fmt.Sprintf("Cron scheduled: %s (TZ=%s, timeout=%s, seconds=%v)\n",
		schedule, loc.String(), timeout, withSeconds))
	timestampedPrint("INFO", fmt.Sprintf("Command: %s %s\n", command, strings.Join(args, " ")))

	// graceful shutdown
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	c.Start()
	defer c.Stop()

	<-stop
	timestampedPrint("INFO", "Shutting down scheduler…\n")
	// c.Stop() aguarda jobs em execução finalizarem;
	// para cancelar imediatamente, controle via contexto acima.
}
